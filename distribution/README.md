# Distribuzione con GitHub Releases

Questa cartella separa chiaramente il canale di pubblicazione dal codice
dell'app. Ogni versione pubblicata contiene un archivio ZIP di `DiskMap.app` e
il suo checksum SHA-256.

## Prima pubblicazione

1. Crea su GitHub un repository privato, ad esempio `diskmap`.
2. Carica questo progetto e aggiorna in `distribution/catalog.json` il valore
   `OWNER` con il tuo account o organizzazione GitHub.
3. Configura in GitHub Actions il certificato **Developer ID Application** e la
   notarizzazione Apple. Fino a quel momento gli artefatti sono solo preview
   locali: la firma ad-hoc non è adatta alla distribuzione esterna.
4. Crea e invia un tag, ad esempio `v0.1`. Il workflow crea una GitHub
   Release con `DiskMap-0.1-macos.zip` e il relativo file `.sha256`.
5. Copia l'hash dal file `.sha256` nel catalogo e pubblica il catalogo in un
   repository `rengul-catalog` (anche privato, se il launcher autenticherà
   l'utente; per un launcher senza login deve essere pubblico).

Nel workflow, l'upload di una GitHub Release è deliberatamente bloccato finché
la variabile Actions `RELEASE_SIGNING_READY` non viene impostata a `true`.
Prima di farlo devono essere configurati certificato Developer ID,
notarizzazione Apple e i rispettivi secret; questo evita di distribuire per
errore le build di sviluppo firmate ad-hoc.

### Secret per GitHub Actions

Nel repository `rengul/diskmap`, apri **Settings → Secrets and variables →
Actions** e crea questi *repository secrets* (mai come variabili normali):

- `DEVELOPER_ID_APPLICATION_P12_BASE64`: il contenuto Base64 dell'export
  `.p12` del certificato **Developer ID Application** con la sua chiave privata.
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`: la password scelta per quell'export.
- `NOTARY_API_KEY_P8_BASE64`: il contenuto Base64 della chiave Apple `.p8`.
- `NOTARY_API_KEY_ID`: il Key ID Apple.
- `NOTARY_ISSUER_ID`: l'Issuer ID Apple.

Crea inoltre le *repository variables*:

- `APP_SIGNING_IDENTITY` = `Developer ID Application: Renato Gulinelli (HU9QF2HFVB)`
- `RELEASE_SIGNING_READY` = `true` (solo dopo avere salvato tutti i secret).

Per ottenere il Base64 senza salvare file aggiuntivi, esegui localmente (il
risultato va incollato direttamente nel relativo secret):

```zsh
base64 -i /percorso/DeveloperID.p12 | tr -d '\n' | pbcopy
base64 -i /percorso/AuthKey_XXXXXXXXXX.p8 | tr -d '\n' | pbcopy
```

## Prima notarizzazione locale

Il primo invio ad Apple va eseguito in locale: conferma che il certificato
Developer ID e la chiave API appartengano allo stesso team, senza esporre
credenziali in GitHub. La chiave `.p8` non deve mai essere copiata nel progetto
o salvata nel repository.

```zsh
cd /Users/renatogulinelli/Documents/Codex/2026-10-14/rie/outputs/daisydisk-cleanroom-scanner

export SIGNING_IDENTITY='Developer ID Application: Renato Gulinelli (HU9QF2HFVB)'
export NOTARY_KEY_PATH='/percorso/completo/AuthKey_XXXXXXXXXX.p8'
export NOTARY_KEY_ID='XXXXXXXXXX'
export NOTARY_ISSUER_ID='xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

make notarize
```

Il comando ricostruisce l'app, la copia in una cartella temporanea pulita
(necessario per evitare metadati Finder aggiunti a `Documents`), firma sia
l'app sia lo scanner incluso con Hardened Runtime e timestamp, invia lo ZIP ad
Apple attendendo l'esito, applica il ticket (`staple`) e verifica firma e
Gatekeeper. Il file finale e pronto in `dist/` solo quando l'esito Apple e
`Accepted`.

## Test locale del pacchetto

```sh
make ui
./distribution/package-release.sh
(cd dist && shasum -a 256 -c DiskMap-*-macos.zip.sha256)
```

Il launcher deve scaricare il catalogo, verificare **prima** lo SHA-256, poi
estrarre l'app in `~/Applications`. Per le versioni finali deve anche imporre
la firma Apple indicata da `teamIdentifier` nel catalogo.

## Struttura consigliata

```
GitHub / diskmap          codice, tag e asset delle release
GitHub / rengul-catalog   catalog.json, elenco delle applicazioni
Launcher                  legge il catalogo e installa in ~/Applications
```

GitHub Releases è una buona prima infrastruttura: non richiede un server e
mantiene asset, note di rilascio e versioni nello stesso punto del codice. Per
file molto grandi o download frequenti potremo in seguito spostare solo gli
asset su Cloudflare R2/S3, senza cambiare il formato del catalogo.
