# Coach Cam — Setup Guide (Windows PC + iPhone, $0)

How it works:

```
Your PC (write code) ──git push──▶ GitHub (Mac builds CoachCam.ipa for free)
                                         │
                       iPhone Safari downloads CoachCam.ipa
                                         │
                   SideStore signs it with your free Apple ID and installs it
```

You do **Parts 1–3 once**. After that, updating is Part 4 and the weekly refresh is Part 5.

---

## Part 1 — Put the code on GitHub (one time)

### 1a. Make the repo **public**
GitHub's own Macs cost nothing on **public** repos. On a free account, a **private** repo gets
2,000 minutes a month, and Mac minutes count **10×**. That leaves about 200 Mac minutes,
or roughly 25–40 builds a month. A public repo has no limit.

Making it public is safe: your Claude API key goes into the iPhone's Keychain inside the app,
**never** into the code. The only downside is that anyone can read your code.

1. Go to <https://github.com/new> (sign up first if you don't have an account).
2. **Repository name:** `CoachCam`
3. Pick **Public**.
4. **Leave all the boxes unchecked**: no README, no .gitignore, no license. We already have those files.
5. Click **Create repository**. Leave the page open; you'll need its URL.

### 1b. Push the code from your PC
Open **PowerShell** (Start menu → type "PowerShell"). Run these commands one at a time, and
replace `YOUR-GITHUB-USERNAME` with your GitHub username:

```bash
cd C:\Users\gunve\CoachCam
```
```bash
git init -b main
```
```bash
git config user.name "Your Name"
```
```bash
git config user.email "gunveersbhatia@gmail.com"
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

The first time you push, a browser window opens asking you to sign in to GitHub. Click
**Sign in with your browser**, then **Authorize**. Windows remembers this, so it only happens once.

### 1c. Watch the build
1. On your repo page, click the **Actions** tab.
2. You'll see a run called **Build IPA**. The yellow dot means it's running; it takes about 4–8 minutes.
3. A **green check** means it worked. A **red X** means it failed: click it, click **build**,
   copy the red error text, and paste it to Claude.

> To re-run a build without changing code: **Actions → Build IPA → Run workflow → Run workflow**.

---

## Part 2 — Set up SideStore (one time, needs your PC and a USB cable)

SideStore is an app store on your phone that signs apps with your free Apple ID.
After this setup you won't need the PC for installing or refreshing.

### 2a. On your iPhone
1. Make sure your iPhone has a **passcode** set.
2. From the App Store, install **LocalDevVPN**. SideStore uses it to talk to your phone from on the phone itself.
3. Open LocalDevVPN, tap **Connect**, and allow the VPN when asked.

### 2b. On your PC
1. Install **iTunes** from Apple: <https://www.apple.com/itunes/download/win64>.
   SideStore recommends Apple's version. If it gives you trouble, use the **Apple Devices** app
   from the Microsoft Store instead.
2. Install **iloader**, SideStore's installer:
   <https://github.com/nab138/iloader/releases/latest/download/iloader-windows-x64.msi>.
   Run the `.msi` and click through.
3. Plug your iPhone into the PC with a USB cable. On the phone, tap **Trust** and enter your passcode.
4. Open **iloader**.
5. Sign in with your **Apple ID**. It's case-sensitive.
   *Optional:* some people use a second, spare Apple ID for sideloading. Either works.
6. Select your iPhone.
7. Click **Install SideStore (Stable)** and wait for it to finish. iloader also creates the
   "pairing file" SideStore needs.

### 2c. Back on your iPhone
1. **Trust your Apple ID as a developer:** Settings → General → **VPN & Device Management** →
   tap your Apple ID under "Developer App" → **Trust** → **Allow & Restart**, then enter your passcode.
2. **Turn on Developer Mode:** Settings → **Privacy & Security** → scroll to the bottom →
   **Developer Mode** → on. The phone restarts; after it does, tap **Turn On**.
3. Open **LocalDevVPN** and tap **Connect**.
4. Open **SideStore** and sign in with the **same Apple ID**.
5. Go to **My Apps** and tap the **7 DAYS** button next to SideStore to refresh it once.
   If it asks about certificates, tap **Yes** or **Refresh Now**.

If something here doesn't match what you see, the official guide is <https://docs.sidestore.io>.

---

## Part 3 — Install Coach Cam

### Option A: straight from your iPhone (easiest)
1. In **Safari** on your iPhone, go to
   `https://github.com/YOUR-GITHUB-USERNAME/CoachCam/releases/tag/latest`.
2. Under **Assets**, tap **CoachCam.ipa** and then **Download**. It goes to Files → Downloads.
3. Open **LocalDevVPN** and make sure it's connected.
4. Open **SideStore** → **My Apps** → tap **+** at the top left → choose **CoachCam.ipa** from Downloads.
5. Wait for it to install, then open **Coach Cam**. You should see **"Hello Coach Cam"** and
   **Build N**, where N matches the "#N" on the release.

### Option B: from the Actions page (on your PC)
1. Go to **Actions → the latest green run** and scroll to **Artifacts**.
2. Download **CoachCam-build-N**. It's a `.zip`; right-click → **Extract All** to get `CoachCam.ipa`.
3. Get the `.ipa` onto your iPhone (iCloud Drive, email it to yourself, etc.) and install it
   with SideStore as in step 4 above.

---

## Part 4 — Updating Coach Cam
Every time new code is pushed, GitHub builds it and replaces the **latest** release. To update:

1. Wait for the green check in **Actions**.
2. Repeat **Part 3, Option A**. Installing over the old version keeps your settings and data.
3. Open the app and check that the **Build** number went up.

---

## Part 5 — Refreshing every 7 days
Free Apple ID signatures expire after **7 days**. When that happens the apps won't open,
but your data is safe.

**Manual (30 seconds):** open **LocalDevVPN** → **Connect**, then open **SideStore** →
**My Apps** → **Refresh All**.

**Automatic (recommended):**
1. Open the **Shortcuts** app → **Automation** → **+** → **Time of Day**.
2. Choose a daily time when your phone is usually on Wi-Fi, and select **Run Immediately**.
3. Add the action **LocalDevVPN → Connect**, if it's offered, then **SideStore → Refresh All Apps**.

⚠️ If **SideStore itself** expires (you went more than 7 days without refreshing), redo
**Part 2b, steps 3–7** with your PC. It takes 2 minutes.

**Free Apple ID limits:** at most **3 sideloaded apps** at a time (SideStore counts as one), and
**10 new app IDs per week**. Coach Cam uses only one.

---

## Troubleshooting
| Problem | Fix |
|---|---|
| Build has a red X | Open the failed run → **build** → copy the error → send it to Claude. |
| "Untrusted Developer" | Part 2c, step 1. |
| SideStore says it can't connect / pairing error | Connect LocalDevVPN. If it still fails, re-run iloader (Part 2b). |
| App closes on launch | In the app's **Debug log** (added in M1) tap **Share**. Or: Settings → Privacy & Security → Analytics & Improvements → Analytics Data → look for `CoachCam-…` and share it. |
| "Maximum number of apps" | Remove another sideloaded app in SideStore. |
