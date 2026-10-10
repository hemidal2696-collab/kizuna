# Kizuna pentru iPhone și iPad

Client PS5 / PS4 Remote Play (chiaki-ng) cu interfață SwiftUI în stil Liquid Glass.
Licență: AGPL-3.0 (vezi `LICENSE.md`).

## Instalare (AltStore Classic)

**Sursă AltStore** (instalare + actualizări automate): în AltStore Classic › Sources › **+**, adaugă

```
https://raw.githubusercontent.com/hemidal2696-collab/kizuna/main/altstore/source.json
```

**Sau IPA direct** (se descarcă fără cont GitHub):

```
https://github.com/hemidal2696-collab/kizuna/releases/download/latest/Kizuna.ipa
```

Ghid complet în română: [`ios/README-ro.md`](ios/README-ro.md).

## Build

Fiecare modificare în `ios/` pornește [workflow-ul](.github/workflows/ios.yml) pe macOS: compilează chiaki-ng + aplicația, publică IPA-ul în release-ul `latest` și actualizează sursa AltStore.
