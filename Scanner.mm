#import <Foundation/Foundation.h>

#include <atomic>
#include <condition_variable>
#include <csignal>
#include <chrono>
#include <dirent.h>
#include <algorithm>
#include <fcntl.h>
#include <fstream>
#include <memory>
#include <mutex>
#include <queue>
#include <string>
#include <sys/stat.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/ioctl.h>
#include <sys/snapshot.h>
#include <thread>
#include <unordered_set>
#include <unordered_map>
#include <vector>
#include <unistd.h>

static volatile sig_atomic_t gCancelRequested = 0;

static void handleInterrupt(int) {
    gCancelRequested = 1;
}

struct FileID {
    dev_t device;
    ino_t inode;
    bool operator==(const FileID &other) const {
        return device == other.device && inode == other.inode;
    }
};

struct FileIDHash {
    size_t operator()(const FileID &value) const {
        return std::hash<uint64_t>{}((uint64_t)value.device) ^
               (std::hash<uint64_t>{}((uint64_t)value.inode) << 1);
    }
};

struct ScanTotals {
    uint64_t files = 0;
    uint64_t directories = 0;
    uint64_t symbolicLinks = 0;
    uint64_t hardLinkDuplicates = 0;
    uint64_t fileIdentityDuplicates = 0;
    uint64_t cloneFiles = 0;
    uint64_t mountPointsSkipped = 0;
    uint64_t firmlinkMirrorsSkipped = 0;
    uint64_t logicalBytes = 0;
    uint64_t physicalBytes = 0;
};

struct ScanNode {
    std::string name;
    std::string path;
    std::string kind;
    uint64_t logicalBytes = 0;
    uint64_t physicalBytes = 0;
    bool duplicateHardLink = false;
    bool clone = false;
    uint64_t cloneID = 0;
    uint32_t cloneReferenceCount = 0;
    bool mountPointSkipped = false;
    bool duplicateDirectory = false;
    bool hiddenSpace = false;
    bool restricted = false;
    std::mutex mutex;
    std::vector<std::shared_ptr<ScanNode>> children;
};

struct WorkItem {
    std::string path;
    std::shared_ptr<ScanNode> node;
};

struct CloneKey {
    dev_t device;
    uint64_t cloneID;
    bool operator==(const CloneKey &other) const {
        return device == other.device && cloneID == other.cloneID;
    }
};

struct CloneKeyHash {
    size_t operator()(const CloneKey &value) const {
        return std::hash<uint64_t>{}((uint64_t)value.device) ^
               (std::hash<uint64_t>{}(value.cloneID) << 1);
    }
};

struct CloneAttributes {
    uint64_t cloneID = 0;
    uint32_t referenceCount = 0;
};

static std::unordered_map<std::string, CloneAttributes>
cloneAttributesInDirectory(const std::string &path) {
    std::unordered_map<std::string, CloneAttributes> result;
    int descriptor = open(path.c_str(), O_RDONLY | O_DIRECTORY);
    if (descriptor < 0) return result;
    struct attrlist attributes {};
    attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
    attributes.commonattr = ATTR_CMN_NAME | ATTR_CMN_RETURNED_ATTRS;
    attributes.forkattr = ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT;
    std::vector<unsigned char> buffer(64 * 1024);
    while (true) {
        int count = getattrlistbulk(descriptor, &attributes, buffer.data(), buffer.size(),
                                    FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED);
        if (count <= 0) break;
        unsigned char *record = buffer.data();
        unsigned char *bufferEnd = buffer.data() + buffer.size();
        for (int index = 0; index < count; ++index) {
            uint32_t length = 0;
            if (record + sizeof(length) > bufferEnd) break;
            memcpy(&length, record, sizeof(length));
            const size_t prefix = sizeof(uint32_t) + sizeof(attribute_set_t);
            if (length < prefix + sizeof(attrreference_t) || record + length > bufferEnd) break;
            auto *returned = reinterpret_cast<attribute_set_t *>(record + sizeof(uint32_t));
            unsigned char *cursor = record + prefix;
            auto *nameReference = reinterpret_cast<attrreference_t *>(cursor);
            unsigned char *nameAddress = cursor + nameReference->attr_dataoffset;
            cursor += sizeof(attrreference_t);
            CloneAttributes clone;
            if (returned->forkattr & ATTR_CMNEXT_CLONEID) {
                if (cursor + sizeof(clone.cloneID) > record + length) break;
                memcpy(&clone.cloneID, cursor, sizeof(clone.cloneID));
                cursor += sizeof(clone.cloneID);
            }
            if (returned->forkattr & ATTR_CMNEXT_CLONE_REFCNT) {
                if (cursor + sizeof(clone.referenceCount) > record + length) break;
                memcpy(&clone.referenceCount, cursor, sizeof(clone.referenceCount));
            }
            if (nameAddress >= record && nameAddress < record + length &&
                nameReference->attr_length > 0 &&
                nameAddress + nameReference->attr_length <= record + length) {
                size_t nameLength = strnlen(reinterpret_cast<char *>(nameAddress),
                                            nameReference->attr_length);
                result.emplace(std::string(reinterpret_cast<char *>(nameAddress), nameLength), clone);
            }
            record += length;
        }
    }
    close(descriptor);
    return result;
}

struct SnapshotInfo {
    std::string name;
    uint64_t objectID = 0;
    uint64_t sizeBytes = 0;
    int sizeError = 0;
};

struct SnapshotListing {
    std::string volumePath;
    std::vector<SnapshotInfo> snapshots;
    int error = 0;
};

static SnapshotListing listSnapshots(const std::string &path, bool includeSizes) {
    SnapshotListing result;
    struct statfs filesystem {};
    if (statfs(path.c_str(), &filesystem) != 0) {
        result.error = errno;
        return result;
    }
    result.volumePath = filesystem.f_mntonname;

    int descriptor = open(result.volumePath.c_str(), O_RDONLY);
    if (descriptor < 0) {
        result.error = errno;
        return result;
    }

    struct attrlist attributes {};
    attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
    attributes.commonattr = ATTR_CMN_NAME | ATTR_CMN_OBJID | ATTR_CMN_RETURNED_ATTRS;
    std::vector<unsigned char> buffer(64 * 1024);
    while (true) {
        int count = fs_snapshot_list(descriptor, &attributes, buffer.data(), buffer.size(), 0);
        if (count < 0) {
            result.error = errno;
            break;
        }
        if (count == 0) break;

        unsigned char *record = buffer.data();
        unsigned char *end = buffer.data() + buffer.size();
        for (int index = 0; index < count; ++index) {
            if (record + sizeof(uint32_t) > end) {
                result.error = EIO;
                break;
            }
            uint32_t length = 0;
            memcpy(&length, record, sizeof(length));
            if (length < sizeof(uint32_t) + sizeof(attribute_set_t) + sizeof(attrreference_t) ||
                record + length > end) {
                result.error = EIO;
                break;
            }
            auto *returned = reinterpret_cast<attribute_set_t *>(record + sizeof(uint32_t));
            if (returned->commonattr & ATTR_CMN_NAME) {
                auto *reference = reinterpret_cast<attrreference_t *>(
                    record + sizeof(uint32_t) + sizeof(attribute_set_t));
                unsigned char *nameAddress = reinterpret_cast<unsigned char *>(reference) +
                                             reference->attr_dataoffset;
                if (nameAddress >= record && nameAddress < record + length &&
                    reference->attr_length > 0 &&
                    nameAddress + reference->attr_length <= record + length) {
                    size_t nameLength = strnlen(reinterpret_cast<char *>(nameAddress),
                                                reference->attr_length);
                    SnapshotInfo info;
                    info.name.assign(reinterpret_cast<char *>(nameAddress), nameLength);
                    unsigned char *nextAttribute = reinterpret_cast<unsigned char *>(reference + 1);
                    if (returned->commonattr & ATTR_CMN_OBJID) {
                        fsobj_id_t objectID {};
                        if (nextAttribute + sizeof(objectID) <= record + length) {
                            memcpy(&objectID, nextAttribute, sizeof(objectID));
                            info.objectID = objectID.fid_objno;
                        }
                    }
                    if (includeSizes && info.objectID != 0) {
                        struct {
                            uint64_t objectIDFrom;
                            uint64_t objectIDTo;
                            uint64_t sizeBytes;
                        } request {info.objectID, info.objectID, 0};
                        if (fsctl(result.volumePath.c_str(), 0xc0184a13UL, &request, 0) == 0)
                            info.sizeBytes = request.sizeBytes;
                        else
                            info.sizeError = errno;
                    }
                    result.snapshots.push_back(std::move(info));
                }
            }
            record += length;
        }
        if (result.error != 0) break;
    }
    close(descriptor);
    std::sort(result.snapshots.begin(), result.snapshots.end(),
              [](const auto &left, const auto &right) { return left.name < right.name; });
    return result;
}

static NSDictionary *volumeSummary(const std::string &path) {
    NSString *nsPath = [NSString stringWithUTF8String:path.c_str()];
    NSURL *url = [NSURL fileURLWithPath:nsPath];
    NSArray *keys = @[
        NSURLVolumeTotalCapacityKey,
        NSURLVolumeAvailableCapacityKey,
        NSURLVolumeAvailableCapacityForImportantUsageKey,
        NSURLVolumeAvailableCapacityForOpportunisticUsageKey
    ];
    NSError *error = nil;
    NSDictionary *values = [url resourceValuesForKeys:keys error:&error];
    if (!values) {
        return @{
            @"error": @{
                @"domain": error.domain ?: @"NSCocoaErrorDomain",
                @"code": @(error.code),
                @"message": error.localizedDescription ?: @"Unknown error"
            }
        };
    }
    uint64_t total = [values[NSURLVolumeTotalCapacityKey] unsignedLongLongValue];
    uint64_t available = [values[NSURLVolumeAvailableCapacityKey] unsignedLongLongValue];
    uint64_t important = [values[NSURLVolumeAvailableCapacityForImportantUsageKey] unsignedLongLongValue];
    uint64_t opportunistic =
        [values[NSURLVolumeAvailableCapacityForOpportunisticUsageKey] unsignedLongLongValue];
    uint64_t purgeableEstimate = important > available ? important - available : 0;
    uint64_t reservedEstimate = 0;
    bool reservedEstimateAvailable = false;
    struct statfs filesystem {};
    NSString *mountPoint = @"";
    NSString *fileSystem = @"";
    if (statfs(path.c_str(), &filesystem) == 0) {
        mountPoint = [NSString stringWithUTF8String:filesystem.f_mntonname];
        fileSystem = [NSString stringWithUTF8String:filesystem.f_fstypename];
        struct attrlist attributes {};
        attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
        attributes.commonattr = ATTR_CMN_RETURNED_ATTRS;
        attributes.volattr = ATTR_VOL_INFO | ATTR_VOL_SIZE | ATTR_VOL_SPACEFREE |
                             ATTR_VOL_SPACEUSED;
        alignas(8) unsigned char buffer[128] {};
        if (getattrlist(filesystem.f_mntonname, &attributes, buffer, sizeof(buffer),
                        FSOPT_REPORT_FULLSIZE) == 0) {
            uint32_t length = 0;
            memcpy(&length, buffer, sizeof(length));
            if (length >= sizeof(uint32_t) + sizeof(attribute_set_t) + 3 * sizeof(uint64_t)) {
                auto *returned = reinterpret_cast<attribute_set_t *>(buffer + sizeof(uint32_t));
                unsigned char *cursor = buffer + sizeof(uint32_t) + sizeof(attribute_set_t);
                uint64_t volumeSize = 0, volumeFree = 0, volumeUsed = 0;
                if (returned->volattr & ATTR_VOL_SIZE) {
                    memcpy(&volumeSize, cursor, sizeof(volumeSize));
                    cursor += sizeof(volumeSize);
                }
                if (returned->volattr & ATTR_VOL_SPACEFREE) {
                    memcpy(&volumeFree, cursor, sizeof(volumeFree));
                    cursor += sizeof(volumeFree);
                }
                if (returned->volattr & ATTR_VOL_SPACEUSED)
                    memcpy(&volumeUsed, cursor, sizeof(volumeUsed));
                const attrgroup_t required = ATTR_VOL_SIZE | ATTR_VOL_SPACEFREE | ATTR_VOL_SPACEUSED;
                if ((returned->volattr & required) == required &&
                    volumeSize >= volumeUsed + volumeFree) {
                    reservedEstimate = volumeSize - volumeUsed - volumeFree;
                    reservedEstimateAvailable = true;
                }
            }
        }
    }
    return @{
        @"mountPoint": mountPoint,
        @"fileSystem": fileSystem,
        @"capacityBytes": @(total),
        @"freeBytes": @(available),
        @"availableForImportantUsageBytes": @(important),
        @"availableForOpportunisticUsageBytes": @(opportunistic),
        @"purgeableEstimateBytes": @(purgeableEstimate),
        @"purgeableEstimateAvailable": @(important != 0 && important >= available),
        @"reservedEstimateBytes": @(reservedEstimate),
        @"reservedEstimateAvailable": @(reservedEstimateAvailable)
    };
}

class ConcurrentScanner {
public:
    ConcurrentScanner(std::string root, size_t workers, bool crossFilesystems, bool showProgress)
        : root_(std::move(root)), workerCount_(workers), crossFilesystems_(crossFilesystems),
          showProgress_(showProgress) {}

    bool scan() {
        struct stat rootStat {};
        if (lstat(root_.c_str(), &rootStat) != 0) {
            addError(root_, errno);
            return false;
        }
        if (!S_ISDIR(rootStat.st_mode)) {
            addError(root_, ENOTDIR);
            return false;
        }
        rootDevice_ = rootStat.st_dev;
        visitedDirectories_.insert({rootStat.st_dev, rootStat.st_ino});
        configureFirmlinkMirrors();
        totals_.directories = 1;
        rootNode_ = std::make_shared<ScanNode>();
        rootNode_->name = root_;
        rootNode_->path = root_;
        rootNode_->kind = "directory";
        enqueue(root_, rootNode_);

        std::vector<std::thread> workers;
        workers.reserve(workerCount_);
        for (size_t i = 0; i < workerCount_; ++i) {
            workers.emplace_back([this] { workerLoop(); });
        }
        std::thread progressThread;
        if (showProgress_) progressThread = std::thread([this] { progressLoop(); });
        for (auto &worker : workers) worker.join();
        scanCancelled_ = cancelRequested();
        workersDone_.store(true);
        if (progressThread.joinable()) progressThread.join();
        aggregateAndSort(rootNode_);
        reconcileVolumeAllocation();
        return !scanCancelled_;
    }

    NSDictionary *jsonResult() {
        std::lock_guard<std::mutex> lock(resultMutex_);
        NSMutableArray *errors = [NSMutableArray arrayWithCapacity:errors_.size()];
        for (const auto &entry : errors_) {
            [errors addObject:@{
                @"path": [NSString stringWithUTF8String:entry.first.c_str()],
                @"errno": @(entry.second),
                @"message": [NSString stringWithUTF8String:strerror(entry.second)]
            }];
        }
        NSMutableArray *restricted = [NSMutableArray arrayWithCapacity:restrictedDirectories_.size()];
        for (const auto &path : restrictedDirectories_)
            [restricted addObject:[NSString stringWithUTF8String:path.c_str()]];
        return @{
            @"root": [NSString stringWithUTF8String:root_.c_str()],
            @"files": @(totals_.files),
            @"directories": @(totals_.directories),
            @"symbolicLinks": @(totals_.symbolicLinks),
            @"hardLinkDuplicates": @(totals_.hardLinkDuplicates),
            @"fileIdentityDuplicates": @(totals_.fileIdentityDuplicates),
            @"cloneFiles": @(totals_.cloneFiles),
            @"cloneGroups": @(cloneGroups_.size()),
            @"restrictedDirectoryCount": @(restrictedDirectories_.size()),
            @"restrictedDirectories": restricted,
            @"mountPointsSkipped": @(totals_.mountPointsSkipped),
            @"firmlinkMirrorsSkipped": @(totals_.firmlinkMirrorsSkipped),
            @"hiddenSpaceBytes": @(hiddenSpaceBytes_),
            @"volumeAllocatedBytes": @(volumeAllocatedBytes_),
            @"unreconciledOvercountBytes": @(unreconciledOvercountBytes_),
            @"logicalBytes": @(totals_.logicalBytes),
            @"physicalBytes": @(totals_.physicalBytes),
            @"cancelled": @(scanCancelled_),
            @"completed": @(rootNode_ != nullptr && !scanCancelled_),
            @"errors": errors
        };
    }

    NSDictionary *treeResult() {
        return rootNode_ ? dictionaryForNode(rootNode_) : nil;
    }

private:
    void enqueue(const std::string &path, const std::shared_ptr<ScanNode> &node) {
        if (cancelRequested()) return;
        std::lock_guard<std::mutex> lock(queueMutex_);
        queue_.push({path, node});
        ++pending_;
        queueCondition_.notify_one();
    }

    void workerLoop() {
        while (true) {
            WorkItem item;
            {
                std::unique_lock<std::mutex> lock(queueMutex_);
                queueCondition_.wait(lock, [this] { return finished_ || !queue_.empty(); });
                if (finished_ && queue_.empty()) return;
                if (cancelRequested()) {
                    const size_t discarded = queue_.size();
                    while (!queue_.empty()) queue_.pop();
                    pending_ -= discarded;
                    if (pending_ == 0) {
                        finished_ = true;
                        queueCondition_.notify_all();
                    }
                    continue;
                }
                item = std::move(queue_.front());
                queue_.pop();
            }
            if (!cancelRequested()) scanDirectory(item);
            {
                std::lock_guard<std::mutex> lock(queueMutex_);
                if (--pending_ == 0) {
                    finished_ = true;
                    queueCondition_.notify_all();
                }
            }
        }
    }

    void scanDirectory(const WorkItem &work) {
        const std::string &path = work.path;
        DIR *directory = opendir(path.c_str());
        if (!directory) {
            int error = errno;
            if (error == EACCES || error == EPERM) {
                work.node->restricted = true;
                addRestrictedDirectory(path);
            }
            addError(path, error);
            return;
        }
        auto cloneAttributes = cloneAttributesInDirectory(path);

        while (dirent *entry = readdir(directory)) {
            if (cancelRequested()) break;
            if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
            std::string child = path;
            if (child.back() != '/') child.push_back('/');
            child.append(entry->d_name);

            struct stat info {};
            if (lstat(child.c_str(), &info) != 0) {
                addError(child, errno);
                continue;
            }

            if (S_ISLNK(info.st_mode)) {
                auto node = makeNode(entry->d_name, child, "symlink");
                addChild(work.node, node);
                std::lock_guard<std::mutex> resultLock(resultMutex_);
                ++totals_.symbolicLinks;
                continue;
            }

            if (S_ISDIR(info.st_mode)) {
                if (firmlinkMirrorPaths_.find(child) != firmlinkMirrorPaths_.end()) {
                    std::lock_guard<std::mutex> resultLock(resultMutex_);
                    ++totals_.firmlinkMirrorsSkipped;
                    continue;
                }
                auto node = makeNode(entry->d_name, child, "directory");
                addChild(work.node, node);
                std::lock_guard<std::mutex> resultLock(resultMutex_);
                ++totals_.directories;
                if (!crossFilesystems_ && info.st_dev != rootDevice_) {
                    ++totals_.mountPointsSkipped;
                    node->mountPointSkipped = true;
                    continue;
                }
                if (!visitedDirectories_.insert({info.st_dev, info.st_ino}).second) {
                    node->duplicateDirectory = true;
                    continue;
                }
                enqueue(child, node);
                continue;
            }

            if (S_ISREG(info.st_mode)) {
                auto node = makeNode(entry->d_name, child, "file");
                node->logicalBytes = (uint64_t)info.st_size;
                node->physicalBytes = (uint64_t)info.st_blocks * 512;
                CloneAttributes clone;
                auto cloneIt = cloneAttributes.find(entry->d_name);
                if (cloneIt != cloneAttributes.end()) clone = cloneIt->second;
                if (clone.referenceCount > 1 && clone.cloneID != 0) {
                    node->clone = true;
                    node->cloneID = clone.cloneID;
                    node->cloneReferenceCount = clone.referenceCount;
                }
                addChild(work.node, node);
                std::lock_guard<std::mutex> resultLock(resultMutex_);
                ++totals_.files;
                if (node->clone) {
                    ++totals_.cloneFiles;
                    ++cloneGroups_[{info.st_dev, node->cloneID}];
                }
                if (!fileIdentities_.insert({info.st_dev, info.st_ino}).second) {
                    ++totals_.fileIdentityDuplicates;
                    if (info.st_nlink > 1) ++totals_.hardLinkDuplicates;
                    node->duplicateHardLink = true;
                    node->logicalBytes = 0;
                    node->physicalBytes = 0;
                    continue;
                }
                totals_.logicalBytes += node->logicalBytes;
                totals_.physicalBytes += node->physicalBytes;
            }
        }
        closedir(directory);
    }

    bool cancelRequested() const {
        return gCancelRequested != 0;
    }

    void progressLoop() {
        while (!workersDone_.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
            ScanTotals current;
            size_t queued = 0;
            {
                std::lock_guard<std::mutex> lock(resultMutex_);
                current = totals_;
            }
            {
                std::lock_guard<std::mutex> lock(queueMutex_);
                queued = pending_;
            }
            fprintf(stderr,
                    "\rfiles=%llu dirs=%llu allocated=%llu MiB pending=%zu%s",
                    (unsigned long long)current.files,
                    (unsigned long long)current.directories,
                    (unsigned long long)(current.physicalBytes / (1024 * 1024)),
                    queued, cancelRequested() ? " cancelling" : "");
            fflush(stderr);
        }
        fputc('\n', stderr);
    }

    static std::shared_ptr<ScanNode> makeNode(const char *name, const std::string &path,
                                              const char *kind) {
        auto node = std::make_shared<ScanNode>();
        node->name = name;
        node->path = path;
        node->kind = kind;
        return node;
    }

    static void addChild(const std::shared_ptr<ScanNode> &parent,
                         const std::shared_ptr<ScanNode> &child) {
        std::lock_guard<std::mutex> lock(parent->mutex);
        parent->children.push_back(child);
    }

    static void aggregateAndSort(const std::shared_ptr<ScanNode> &node) {
        if (node->kind != "directory") return;
        for (const auto &child : node->children) {
            aggregateAndSort(child);
            node->logicalBytes += child->logicalBytes;
            node->physicalBytes += child->physicalBytes;
        }
        std::sort(node->children.begin(), node->children.end(),
                  [](const auto &left, const auto &right) {
                      if (left->physicalBytes != right->physicalBytes)
                          return left->physicalBytes > right->physicalBytes;
                      return left->name < right->name;
                  });
    }

    void configureFirmlinkMirrors() {
        if (root_ != "/") return;
        std::ifstream input("/usr/share/firmlinks");
        std::string line;
        while (std::getline(input, line)) {
            if (line.empty() || line[0] == '#') continue;
            size_t separator = line.find_first_of("\t ");
            if (separator == std::string::npos) continue;
            size_t targetStart = line.find_first_not_of("\t ", separator);
            if (targetStart == std::string::npos) continue;
            std::string target = line.substr(targetStart);
            while (!target.empty() && (target.back() == '\r' || target.back() == ' ' ||
                                       target.back() == '\t')) target.pop_back();
            while (!target.empty() && target.front() == '/') target.erase(target.begin());
            if (!target.empty())
                firmlinkMirrorPaths_.insert("/System/Volumes/Data/" + target);
        }
    }

    void reconcileVolumeAllocation() {
        struct statfs filesystem {};
        if (statfs(root_.c_str(), &filesystem) != 0 || root_ != filesystem.f_mntonname) return;
        NSDictionary *summary = volumeSummary(root_);
        if (![summary isKindOfClass:NSDictionary.class] || summary[@"error"]) return;
        uint64_t capacity = [summary[@"capacityBytes"] unsignedLongLongValue];
        uint64_t free = [summary[@"freeBytes"] unsignedLongLongValue];
        if (capacity == 0 || free > capacity) return;
        volumeAllocatedBytes_ = capacity - free;
        uint64_t scanned = rootNode_->physicalBytes;
        if (volumeAllocatedBytes_ > scanned) {
            hiddenSpaceBytes_ = volumeAllocatedBytes_ - scanned;
            auto hidden = makeNode("hidden space", "", "hidden-space");
            hidden->physicalBytes = hiddenSpaceBytes_;
            hidden->hiddenSpace = true;
            rootNode_->children.push_back(hidden);
            rootNode_->physicalBytes += hiddenSpaceBytes_;
            totals_.physicalBytes += hiddenSpaceBytes_;
            std::sort(rootNode_->children.begin(), rootNode_->children.end(),
                      [](const auto &left, const auto &right) {
                          if (left->physicalBytes != right->physicalBytes)
                              return left->physicalBytes > right->physicalBytes;
                          return left->name < right->name;
                      });
        } else if (scanned > volumeAllocatedBytes_) {
            unreconciledOvercountBytes_ = scanned - volumeAllocatedBytes_;
        }
    }

    static NSDictionary *dictionaryForNode(const std::shared_ptr<ScanNode> &node) {
        NSMutableDictionary *result = [@{
            @"name": [NSString stringWithUTF8String:node->name.c_str()],
            @"path": [NSString stringWithUTF8String:node->path.c_str()],
            @"kind": [NSString stringWithUTF8String:node->kind.c_str()],
            @"logicalBytes": @(node->logicalBytes),
            @"physicalBytes": @(node->physicalBytes)
        } mutableCopy];
        if (node->duplicateHardLink) result[@"duplicateHardLink"] = @YES;
        if (node->clone) {
            result[@"clone"] = @YES;
            result[@"cloneID"] = @(node->cloneID);
            result[@"cloneReferenceCount"] = @(node->cloneReferenceCount);
        }
        if (node->mountPointSkipped) result[@"mountPointSkipped"] = @YES;
        if (node->duplicateDirectory) result[@"duplicateDirectory"] = @YES;
        if (node->hiddenSpace) result[@"hiddenSpace"] = @YES;
        if (node->restricted) result[@"restricted"] = @YES;
        if (!node->children.empty()) {
            NSMutableArray *children = [NSMutableArray arrayWithCapacity:node->children.size()];
            for (const auto &child : node->children) [children addObject:dictionaryForNode(child)];
            result[@"children"] = children;
        }
        return result;
    }

    void addError(const std::string &path, int error) {
        std::lock_guard<std::mutex> lock(resultMutex_);
        errors_.emplace_back(path, error);
    }

    void addRestrictedDirectory(const std::string &path) {
        std::lock_guard<std::mutex> lock(resultMutex_);
        restrictedDirectories_.push_back(path);
    }

    std::string root_;
    size_t workerCount_;
    bool crossFilesystems_;
    bool showProgress_;
    dev_t rootDevice_ = 0;
    std::atomic<bool> workersDone_ {false};
    bool scanCancelled_ = false;

    std::mutex queueMutex_;
    std::condition_variable queueCondition_;
    std::queue<WorkItem> queue_;
    size_t pending_ = 0;
    bool finished_ = false;

    std::mutex resultMutex_;
    ScanTotals totals_;
    std::unordered_set<FileID, FileIDHash> visitedDirectories_;
    std::unordered_set<FileID, FileIDHash> fileIdentities_;
    std::unordered_set<std::string> firmlinkMirrorPaths_;
    std::unordered_map<CloneKey, uint64_t, CloneKeyHash> cloneGroups_;
    std::vector<std::pair<std::string, int>> errors_;
    std::vector<std::string> restrictedDirectories_;
    std::shared_ptr<ScanNode> rootNode_;
    uint64_t hiddenSpaceBytes_ = 0;
    uint64_t volumeAllocatedBytes_ = 0;
    uint64_t unreconciledOvercountBytes_ = 0;
};

static void usage(const char *program) {
    fprintf(stderr, "Usage: %s [--threads N] [--cross-filesystems] [--tree] [--progress] [--snapshots] [--snapshot-sizes] [--volume-summary] PATH\n", program);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        size_t threads = MAX((size_t)1, (size_t)std::thread::hardware_concurrency());
        bool crossFilesystems = false;
        bool includeTree = false;
        bool showProgress = false;
        bool includeSnapshots = false;
        bool includeSnapshotSizes = false;
        bool includeVolumeSummary = false;
        std::string path;

        for (int i = 1; i < argc; ++i) {
            if (!strcmp(argv[i], "--threads") && i + 1 < argc) {
                char *end = nullptr;
                unsigned long value = strtoul(argv[++i], &end, 10);
                if (!end || *end || value == 0 || value > 256) {
                    usage(argv[0]);
                    return 2;
                }
                threads = (size_t)value;
            } else if (!strcmp(argv[i], "--cross-filesystems")) {
                crossFilesystems = true;
            } else if (!strcmp(argv[i], "--tree")) {
                includeTree = true;
            } else if (!strcmp(argv[i], "--progress")) {
                showProgress = true;
            } else if (!strcmp(argv[i], "--snapshots")) {
                includeSnapshots = true;
            } else if (!strcmp(argv[i], "--snapshot-sizes")) {
                includeSnapshots = true;
                includeSnapshotSizes = true;
            } else if (!strcmp(argv[i], "--volume-summary")) {
                includeVolumeSummary = true;
            } else if (path.empty()) {
                path = argv[i];
            } else {
                usage(argv[0]);
                return 2;
            }
        }

        if (path.empty()) {
            usage(argv[0]);
            return 2;
        }

        char resolved[PATH_MAX];
        if (!realpath(path.c_str(), resolved)) {
            perror("realpath");
            return 1;
        }

        struct sigaction action {};
        action.sa_handler = handleInterrupt;
        sigemptyset(&action.sa_mask);
        sigaction(SIGINT, &action, nullptr);
        sigaction(SIGTERM, &action, nullptr);

        ConcurrentScanner scanner(resolved, threads, crossFilesystems, showProgress);
        bool success = scanner.scan();
        NSError *error = nil;
        NSMutableDictionary *output = [scanner.jsonResult() mutableCopy];
        if (includeTree) output[@"tree"] = scanner.treeResult();
        if (includeVolumeSummary) output[@"volumeSummary"] = volumeSummary(resolved);
        if (includeSnapshots) {
            SnapshotListing snapshots = listSnapshots(resolved, includeSnapshotSizes);
            NSMutableArray *items = [NSMutableArray arrayWithCapacity:snapshots.snapshots.size()];
            for (const auto &snapshot : snapshots.snapshots) {
                NSMutableDictionary *item = [@{
                    @"name": [NSString stringWithUTF8String:snapshot.name.c_str()],
                    @"objectID": @(snapshot.objectID)
                } mutableCopy];
                if (includeSnapshotSizes) {
                    if (snapshot.sizeError == 0)
                        item[@"sizeBytes"] = @(snapshot.sizeBytes);
                    else
                        item[@"sizeError"] = @{
                            @"errno": @(snapshot.sizeError),
                            @"message": [NSString stringWithUTF8String:strerror(snapshot.sizeError)]
                        };
                }
                [items addObject:item];
            }
            output[@"snapshotVolume"] = [NSString stringWithUTF8String:snapshots.volumePath.c_str()];
            output[@"snapshots"] = items;
            if (snapshots.error != 0) {
                output[@"snapshotError"] = @{
                    @"errno": @(snapshots.error),
                    @"message": [NSString stringWithUTF8String:strerror(snapshots.error)]
                };
            }
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:output
                                                       options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                         error:&error];
        if (!json) {
            fprintf(stderr, "JSON serialization failed: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        if (fwrite(json.bytes, 1, json.length, stdout) != json.length ||
            fputc('\n', stdout) == EOF || fflush(stdout) == EOF) {
            fprintf(stderr, "Cannot write scan results: %s\n", strerror(errno));
            return 1;
        }
        return success ? 0 : 1;
    }
}
