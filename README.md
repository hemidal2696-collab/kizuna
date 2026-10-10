# Kizuna

Client PS5 / PS4 Remote Play (chiaki-ng) cu design Liquid Glass × PlayStation × Nintendo Switch 2,
pentru **Nintendo Switch 1** (homebrew, Atmosphère) și pentru **iPhone / iPad**.
Licență: AGPL-3.0 (vezi `LICENSE.md`).

## Nintendo Switch

Descarcă `kizuna.nro` din [Releases](https://github.com/hemidal2696-collab/kizuna/releases) (ultima versiune `vX.Y.Z`)
și copiază-l în `SD:/switch/kizuna/kizuna.nro`. La prima pornire din Homebrew Menu, Kizuna se oferă să-și pună
iconița pe ecranul HOME (necesită sys-patch).

Actualizări: **Settings › Updates** în aplicație (de la 1.0.1). Ghidul complet în română este în arhiva
`Kizuna-Switch-X.Y.Z.zip` (`CITESTE-MA.md`).

Sursa: aplicația Switch este un fork al [Akira](https://github.com/chiaki-ng/akira) v0.6.5. Fiecare versiune are atașat
`kizuna-switch-vs-akira-0.6.5.patch`, cu toate modificările (inclusiv cele din borealis).

## iPhone și iPad (SideStore / AltStore)

**Sursă** (instalare + actualizări automate): în SideStore sau AltStore Classic › Sources › **+**, adaugă

```
https://raw.githubusercontent.com/hemidal2696-collab/kizuna/main/altstore/source.json
```

**Sau IPA direct** (se descarcă fără cont GitHub):

```
https://github.com/hemidal2696-collab/kizuna/releases/download/latest/Kizuna.ipa
```

Ghid complet în română: [`ios/README-ro.md`](ios/README-ro.md).

### Build iOS

Fiecare modificare în `ios/` pornește [workflow-ul](.github/workflows/ios.yml) pe macOS: compilează chiaki-ng + aplicația,
publică IPA-ul în release-ul `latest` și actualizează sursa AltStore/SideStore.
