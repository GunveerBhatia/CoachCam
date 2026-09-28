# Coach Cam — Setup Guide (Windows PC + iPhone, $0)

How it works:

```
Your PC (write code) ──git push──▶ GitHub (Mac builds CoachCam.ipa for free)
                                         │
                        your PC downloads CoachCam.ipa
                                         │
       iloader (on your PC, iPhone plugged in by USB) signs it with your
       free Apple ID and installs it on the iPhone
```

You do **Parts 1–2 once**. After that: install or update = Part 3, weekly refresh = Part 4.

> **Why iloader and not SideStore?** SideStore's sign-in currently fails with
> **"ADI native error (-45061)"**, a known SideStore bug. Until that's fixed we install
> **and** refresh with **iloader's Import IPA** from the PC. See Part 5 for switching back
> later.

> ⚠️ **Only download iloader from its real GitHub page:**
> **<https://github.com/nab138/iloader/releases>**
> There are fake "iloader" sites. Never download it from anywhere else, and never type your
> Apple ID into a website.

---

## Part 1 — Put the code on GitHub (one time) ✅ done

### 1a. Make the repo **public**
GitHub's own Macs cost nothing on **public** repos. On a free account, a **private** repo gets
2,000 minutes a month, and Mac minutes count **10×**. That leaves about 200 Mac minutes,
or roughly 25–40 builds a month. A public repo has no limit.

Making it public is safe: your Claude API key goes into the iPhone's Keychain inside the app,
**never** into the code. The only downside is that anyone can read your code.

1. Go to <https://github.com/new> (sign up first if you don't have an account).
2. **Repository name:** `CoachCam`
3. Pick **Public**.
4. **Leave all the boxes unchecked**: no README, no .gitignore, no license.
5. Click **Create repository**.

### 1b. Push the code from your PC
In **PowerShell**, run these one at a time (replace `YOUR-GITHUB-USERNAME`):

```bash
cd C:\Users\gunve\CoachCam
```
```bash
git init -b main
```
```bash
git add .
```
```bash
git commit -m "M0: pipeline"
```
```bash
git remote add origin https://github.com/YOUR-GITHUB-USERNAME/CoachCam.git
```
```bash
git push -u origin main
```

The first push opens a **Connect to GitHub** window. Click **Sign in with your browser**, then
**Authorize**. Windows remembers this, so it only happens once.

### 1c. Watch the build
1. On your repo page, click the **Actions** tab.
2. The run called **Build IPA** takes about 4–8 minutes. A **green check** means it worked.
3. A **red X** means it failed: click it → **build** → copy the red error text → send it to Claude.

> To re-run a build without changing code: **Actions → Build IPA → Run workflow → Run workflow**.

---

## Part 2 — Set up iloader (one time) ✅ done

### 2a. On your PC
1. Install **iTunes** from Apple: <https://www.apple.com/itunes/download/win64>.
   If it gives you trouble, use the **Apple Devices** app from the Microsoft Store instead.
2. Go to **<https://github.com/nab138/iloader/releases>**. Under the newest release, open
   **Assets** (click **Show all assets** if the list is cut off) and download
   **`iloader-windows-x64.msi`**. Run it and click through.
3. Plug your iPhone into the PC with a USB cable. On the phone, tap **Trust** and enter your passcode.
4. Open **iloader**, sign in with your **Apple ID** (case-sensitive), and select your iPhone.

### 2b. On your iPhone (after the first app is installed in Part 3)
1. **Trust your Apple ID as a developer:** Settings → General → **VPN & Device Management** →
   tap your Apple ID under "Developer App" → **Trust** → **Allow & Restart**, then enter your passcode.
2. **Turn on Developer Mode:** Settings → **Privacy & Security** → scroll to the bottom →
   **Developer Mode** → on. The phone restarts; after it does, tap **Turn On**.

You only do these once. They stay on across reinstalls.

---

## Part 3 — Install or update Coach Cam (iloader, PC + USB)

1. On your PC, wait for the newest build in **Actions** to show a green check.
2. Download the newest `.ipa`:
   **<https://github.com/GunveerBhatia/CoachCam/releases/download/latest/CoachCam.ipa>**
   (or open the repo → **Releases** → **Latest build #N** → **CoachCam.ipa**).
3. Plug in your iPhone and unlock it.
4. Open **iloader** → select your iPhone → **Import IPA** → choose the `CoachCam.ipa` you
   just downloaded. Wait until it says it's done.
5. Open **Coach Cam** on the phone and check that the **Build** number matches the "#N" on
   the release. In M1 and later, the build number is in **Settings** (gear icon) → **About**.

Installing over the old version **keeps your settings, log and data**.

> Make sure you pick the **new** `.ipa`. If Windows saved it as `CoachCam (1).ipa`, delete the
> old ones from Downloads so you don't import a stale build.

---

## Part 4 — Refresh every 7 days
Apps signed with a free Apple ID stop opening after **7 days**. Your data is safe; the app
just won't launch until it's re-signed.

**To refresh:** do **Part 3, steps 2–4** again. Re-importing the latest `.ipa` re-signs it
for another 7 days. It takes about a minute and needs the PC and USB cable.

Tips:
- Coach Cam shows **"Signature expires in N days"** in **Settings → About** (from M1 on).
- Set a weekly reminder on your phone, e.g. every Sunday: "Refresh Coach Cam (iloader)".
- iloader has no automatic refresh yet. Its developer lists auto-refresh as a planned feature.

**Free Apple ID limits:** at most **3 sideloaded apps** at a time, and **10 new app IDs per
week**. Coach Cam uses only one app ID, and re-importing it doesn't use a new one. SideStore
also counts toward the 3 while it's installed; you can delete it from the phone until its
sign-in bug is fixed.

---

## Part 5 — Later: back to SideStore (optional)
Once SideStore fixes the ADI (-45061) sign-in bug, SideStore can refresh apps on the phone
with no PC:
1. Install **LocalDevVPN** from the App Store and tap **Connect**.
2. In iloader, click **Install SideStore (Stable)**.
3. In SideStore, sign in, then **My Apps → +** → pick `CoachCam.ipa`; refresh with **Refresh All**.

Official guide: <https://docs.sidestore.io>. Until then, stick with Parts 3–4.

---

## Troubleshooting
| Problem | Fix |
|---|---|
| Build has a red X | Open the failed run → **build** → copy the error → send it to Claude. |
| "Untrusted Developer" | Part 2b, step 1. |
| iloader doesn't see the iPhone | Unlock the phone, re-plug the cable, tap **Trust**. Reinstall iTunes or Apple Devices if it still fails. |
| "Maximum number of apps" | Delete another sideloaded app (e.g. SideStore) from the phone. |
| App closes on launch | Settings → Privacy & Security → Analytics & Improvements → Analytics Data → look for `CoachCam-…` and share it. |
| Something wrong inside the app | Coach Cam **Settings → Debug log → Share** and send it to Claude. The log is also in the **Files** app → On My iPhone → Coach Cam. |
