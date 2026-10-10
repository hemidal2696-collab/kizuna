# Kizuna pentru iPhone și iPad

Kizuna (絆, „legătură”) este un client **PS5 / PS4 Remote Play** pentru iOS și iPadOS,
construit peste biblioteca de protocol **chiaki-ng** (AGPL-3.0), cu o interfață SwiftUI
în stilul Liquid Glass de la Apple, cu accente PS5 și Nintendo Switch 2.
Este varianta iOS a Kizuna pentru Nintendo Switch (din folderul `switch/`).

Ce face:

- **Conectare cu contul PlayStation**, ca aplicația oficială. Kizuna află singur
  ID-ul contului și **asociază consola fără PIN** (prin serverele PSN).
  Asocierea clasică cu PIN-ul de 8 cifre rămâne disponibilă.
- Găsește consolele din rețeaua locală, arată dacă sunt **pornite** sau în **repaus**
  și le poate **trezi**.
- Stream video **HEVC sau H.264** decodat hardware (VideoToolbox), 720p/1080p, 30/60 fps,
  debit 5–50 Mbps, cu profilele *Latență minimă*, *Echilibrat* și *Calitate maximă*.
- Sunet cu latență mică (~30–60 ms în buffer), fără distorsiuni.
- Controlere: **DualSense** (touchpad, giroscop, haptică, triggere adaptive, culoarea
  barei de lumină), DualShock 4, Xbox, Switch Pro, MFi. Fără controler apar
  **comenzi pe ecran** (D-pad, butoane, L1/R1/L2/R2, stick-uri, Create/PS/Options, touchpad).
- Stream și **din afara casei** prin PSN (pentru consolele asociate prin cont).
- Interfață în **română** (implicit) și engleză.

> Proiectul a fost scris pe Windows, fără Mac: aplicația se compilează pe un runner
> macOS din GitHub Actions. Nu a fost încă testată pe un iPhone/iPad real — vezi
> secțiunea [Limitări](#limitări).

---

## 1. Cum obții fișierul IPA

### Varianta A — GitHub Actions (fără Mac)

1. Fă-ți cont pe <https://github.com> (gratuit).
2. Creează un repository **privat** nou, de exemplu `kizuna`.
3. Urcă în el **tot folderul `Kizuna`** (rădăcina repository-ului trebuie să conțină
   `ios/` și `.github/workflows/ios.yml`). Cel mai simplu, din folderul `Kizuna`:
   ```
   git init
   git add ios .github
   git commit -m "Kizuna iOS"
   git branch -M main
   git remote add origin https://github.com/<utilizator>/kizuna.git
   git push -u origin main
   ```
   (Sau din browser: *Add file › Upload files* și tragi folderele `ios` și `.github`.)
4. Deschide fila **Actions**. Workflow-ul **„iOS (IPA nesemnat)”** pornește singur la
   fiecare push (sau îl pornești manual: *Run workflow*).
5. Prima rulare durează ~20–30 de minute (se compilează chiaki-ng, mbedTLS, curl, Opus…);
   rulările următoare refolosesc biblioteca din cache și durează câteva minute.
6. La final, în pagina rulării, secțiunea **Artifacts** conține
   **`Kizuna-unsigned-ipa`** → descarcă-l și dezarhivează-l: obții `Kizuna-unsigned.ipa`.

### Varianta B — pe un Mac

Ai nevoie de Xcode 26.x, Homebrew și Python 3:

```
brew install xcodegen protobuf ninja cmake
cd ios
bash scripts/build-core.sh       # construiește Vendor/lib/libKizunaCore.a
xcodegen generate                # creează Kizuna.xcodeproj
open Kizuna.xcodeproj            # alegi echipa ta la Signing și rulezi pe dispozitiv
```

Sau IPA nesemnat din linia de comandă:

```
xcodebuild -project Kizuna.xcodeproj -scheme Kizuna -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/DD \
  CODE_SIGNING_ALLOWED=NO build
mkdir -p build/ipa/Payload && cp -R build/DD/Build/Products/Release-iphoneos/Kizuna.app build/ipa/Payload/
(cd build/ipa && zip -qry ../Kizuna-unsigned.ipa Payload)
```

Biblioteca nativă este doar pentru dispozitive reale (arm64, `iphoneos`); simulatorul
nu este suportat.

---

## 2. Instalare (sideload)

IPA-ul este **nesemnat**; îl semnezi la instalare cu Apple ID-ul tău (gratuit merge).

- **SideStore** (direct pe telefon, recomandat) sau **AltStore** (cu AltServer pe PC):
  *My Apps › +* și alegi `Kizuna-unsigned.ipa`.
- **Sideloadly** (Windows/macOS): conectezi telefonul prin cablu, tragi IPA-ul în
  fereastră, introduci Apple ID-ul și apeși *Start*.

Important:

- Pe iOS 16+ trebuie activat **Modul dezvoltator**: *Setări › Confidențialitate și
  securitate › Mod dezvoltator* (apare după prima instalare), apoi repornire.
- Cu un Apple ID gratuit, semnătura expiră după **7 zile**: SideStore/AltStore o
  reîmprospătează automat; cu Sideloadly reinstalezi.
- Un cont gratuit permite maximum 3 aplicații sideload active și 10 ID-uri de aplicație
  pe săptămână. Dacă identificatorul `ro.kizuna.remoteplay` intră în conflict,
  Sideloadly/AltStore îl modifică automat.
- Dacă vezi „Untrusted Developer”: *Setări › General › VPN și gestionare dispozitive*
  › Apple ID-ul tău › *Ai încredere*.

---

## 3. Prima rulare

Pe consolă (o singură dată):

- PS5: *Setări › Sistem › Redare la distanță › Activează Redarea la distanță*.
- Pentru trezire din repaus: *Setări › Sistem › Economisire energie › Funcții disponibile
  în modul repaus › Rămâi conectat la internet* și *Activează pornirea PS5 din rețea*.
- PS4: *Setări › Setări conexiune Redare la distanță › Activează Redarea la distanță*
  și setează consola ca **PS4 principal** al contului.

În aplicație:

1. La prima pornire iOS cere permisiunea **Rețea locală** → *Permite*. Fără ea Kizuna nu
   vede consola. (Poți schimba ulterior din *Setări › Kizuna › Rețea locală*.)
2. **Adaugă consolă** (+) → **Conectează-te la PlayStation Network**. Te autentifici pe
   pagina Sony (inclusiv 2FA). Kizuna păstrează sesiunea în Keychain.
3. Apare lista consolelor contului → **Asociază automat**. Consola trebuie să fie pornită
   sau în repaus cu „Rămâi conectat la internet”. Asocierea durează 10–30 de secunde.
4. Înapoi pe ecranul principal: **Conectare**. Dacă telefonul nu e în aceeași rețea,
   din meniul „…” al consolei alegi **Conectare prin internet**.

Dacă pagina de login nu se finalizează: butonul cu clipboard din dreapta sus permite
lipirea manuală a adresei de redirecționare (conține `?code=`) sau a codului **NPSSO**
(îl obții logat pe playstation.com, din <https://ca.account.sony.com/api/v1/ssocookie>).

Fără cont PSN: *Manual (adresă IP + PIN)* — pe consolă *Redare la distanță › Asociază
dispozitivul* afișează PIN-ul de 8 cifre; ai nevoie și de ID-ul contului PSN (base64).

---

## 4. Sfaturi pentru control

- **DualSense**: conectează-l prin Bluetooth (*Setări › Bluetooth*, ține apăsat Create + PS
  până clipește). Funcționează touchpad-ul, giroscopul, vibrațiile și triggerele adaptive.
  Butonul PS ajunge la consolă (gestul de sistem al iOS e dezactivat în timpul jocului).
- **Xbox / Switch Pro**: maparea e pozițională (butonul de jos = ✕). Pentru aranjamentul
  Nintendo activează *Inversează A/B* în setările streamului.
- **Meniul rapid** (butonul cu pătrățele din colțul dreapta-sus): buton PS, clic touchpad,
  captură (ține apăsat Create, scurtătura implicită a consolei), statistici, comenzi pe
  ecran, punere în repaus, deconectare.
- Comenzi pe ecran: atingere scurtă pe un stick = L3/R3; atingere scurtă pe touchpad = clic.
- Pentru latență minimă: Wi-Fi de 5 GHz/6 GHz, consola pe cablu, profilul *Latență minimă*.
  Căștile Bluetooth adaugă 100–200 ms la sunet.

---

## 5. Limitări

- **Netestat pe dispozitiv**: codul a fost scris și verificat static (shim-ul C este
  compilat de verificare cu antetele reale chiaki-ng v1.10.0), dar aplicația nu a rulat
  încă pe un iPhone/iPad. Prima compilare pe macOS poate scoate la iveală mici erori.
- **Descoperire fără multicast**: iOS cere un entitlement special Apple
  (`com.apple.developer.networking.multicast`) pentru broadcast. Kizuna trimite în schimb
  pachete *unicast* către fiecare adresă din rețeaua /24 a telefonului (și direct la
  adresa salvată). Rețele mai mari decât /24 sau consola pe altă subrețea → adaugă IP-ul
  manual.
- **HDR** este dezactivat (stream SDR).
- **Haptica DualSense** este aproximată: iOS nu permite trimiterea formei de undă brute
  către actuatoare, așa că semnalul haptic este redus la o intensitate pe fiecare parte
  (CoreHaptics). Unele efecte de triggere adaptive sunt aproximate cu cel mai apropiat mod
  oferit de Apple.
- **Microfonul** și tastatura de pe ecran a consolei nu sunt implementate.
- **Captura** apasă lung butonul Create; dacă ai schimbat scurtătura pe consolă,
  comportamentul diferă.
- **Prin internet**: depinde de NAT. Funcționează de obicei; pe rețele mobile cu CGNAT
  simetric conexiunea poate eșua (biblioteca încearcă de 3 ori).
- PS4: e nevoie de firmware 7.0+ pentru asocierea cu ID de cont (variantele mai vechi cer
  Online ID, nesuportat aici). Codec-ul pe PS4 este mereu H.264.
- Dacă semnarea sideload nu oferă acces la Keychain, datele sunt păstrate în spațiul
  aplicației (mai puțin protejate) — vezi jurnalul tehnic din Setări.
- Linkul „Cod sursă” din *Setări › Despre* este un placeholder
  (`SettingsView.sourceURL`): înlocuiește-l cu adresa repository-ului tău înainte de a
  distribui aplicația (obligație AGPL-3.0, secțiunea 13).
- Simulatorul iOS nu este suportat (biblioteca nativă e compilată doar pentru `iphoneos`).

---

## 6. Structura proiectului

```
ios/
  project.yml                XcodeGen (țintă „Kizuna”, iOS 17.0, iPhone + iPad)
  Core/                      shim C peste chiaki-ng (KizunaCore.h/.c) + CMakeLists.txt
  scripts/build-core.sh      descarcă chiaki-ng v1.10.0, aplică patch-uri, compilează libKizunaCore.a
  scripts/patch_chiaki.py    patch-uri (deployment target, holepunch fără libevent)
  Kizuna/App                 intrarea aplicației, AppModel, Keychain, modele
  Kizuna/Core                legătura Swift ↔ C (descoperire, asociere, jurnal)
  Kizuna/PSN                 autentificare PSN (WKWebView, OAuth, NPSSO, lista consolelor)
  Kizuna/Stream              video (AVSampleBufferDisplayLayer), audio, intrări, haptică, ecranul de joc
  Kizuna/UI                  ecrane SwiftUI (Liquid Glass), temă, traduceri
../.github/workflows/ios.yml  build în GitHub Actions → Kizuna-unsigned.ipa
```

Biblioteca nativă: chiaki-ng **v1.10.0** (commit `0c4a45df0cae2af2ba2daef84e881850b07038a3`),
mbedTLS 2.28, curl 8.11 (Secure Transport, WebSocket), json-c 0.17, miniupnpc 2.2.8,
Opus 1.5.2, nanopb, Jerasure — toate statice, unite în `Vendor/lib/libKizunaCore.a`.

---

## 7. Licență

Kizuna este software liber, distribuit sub **GNU Affero General Public License v3.0**
(AGPL-3.0). Include sau adaptează cod din:

- **chiaki-ng** — LicenseRef-AGPL-3.0-only-OpenSSL, © contribuitorii chiaki / chiaki-ng
- **Akira** (fork-ul Switch din care provine Kizuna pentru Switch) — AGPL-3.0
- **TP Play** — AGPL-3.0 (shim C, parsare NAL, script de build)
- **Pylux** — AGPL-3.0 (login WebView, triggere adaptive, maparea senzorilor)

Dacă distribui aplicația (inclusiv un IPA), trebuie să oferi și codul sursă complet al
versiunii respective. PlayStation, PS5, PS4 și DualSense sunt mărci înregistrate ale
Sony Interactive Entertainment; Kizuna nu este afiliat cu Sony.
