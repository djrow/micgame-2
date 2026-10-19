# SignPath Foundation Setup Guide (`micgame-2`)

This project is pre-configured for free open-source Windows Authenticode code signing via the **[SignPath Foundation](https://about.signpath.io/product/open-source)**.

---

## Step 1: Initialize Git & Push to a Public GitHub Repository

From `c:\Users\david\Documents\micgame-2`, run:

```powershell
git init
git add .
git commit -m "Initial open-source release with SignPath CI workflow"
git branch -M main
git remote add origin https://github.com/djrow/micgame-2.git
git push -u origin main
```

*(Note: `.gitignore` automatically excludes your local `micgame3.exe`, `micgame3.apk`, `.godot/`, and pre-compiled `.dll`/`.so` files so the repository contains strictly source code and assets, as required by SignPath.)*

---

## Step 2: Run the GitHub Actions Workflow Once

1. On GitHub, open your repository -> **Actions** tab.
2. Select **Build & Sign Windows Release** -> click **Run workflow**.
3. Wait ~2 minutes for the build to turn green and produce the `unsigned-windows-zip` artifact.
   - SignPath reviewers inspect this workflow run when approving your application.

---

## Step 3: Submit the SignPath Open Source Application

Apply at **[https://about.signpath.io/product/open-source](https://about.signpath.io/product/open-source)** with:
- **Project Name**: `Mic Rhythm Prototype` (`micgame-2`)
- **License**: `MIT License` (`LICENSE` in root)
- **Source Code Repository URL**: `https://github.com/djrow/micgame-2`
- **Build System**: `GitHub Actions` (`.github/workflows/release-windows.yml`)

---

## Step 4: Configure SignPath Artifact Configuration & Secrets (After Approval)

Once SignPath approves your project:

### 1. Artifact Configuration XML (in SignPath Portal)
Create an Artifact Configuration named `windows-zip` in SignPath using the following XML policy. It instructs SignPath to open `micgame3-windows-x86_64.zip`, sign `micgame3.exe` and `libonnx_pitch.windows.x86_64.dll` inside it, and leave Microsoft's existing signature on `onnxruntime.dll` intact:

```xml
<artifact-configuration xmlns="http://signpath.io/schema/artifact-configuration/v1">
  <zip-file>
    <pe-file path="micgame3.exe" />
    <pe-file path="libonnx_pitch.windows.x86_64.dll" />
    <file path="onnxruntime.dll" />
    <file path="LICENSE.txt" />
  </zip-file>
</artifact-configuration>
```

### 2. GitHub Repository Secret & Variables
In your GitHub repository -> **Settings** -> **Secrets and variables** -> **Actions**:
- **Secret**:
  - `SIGNPATH_API_TOKEN`: Your SignPath CI User API token.
- **Variables**:
  - `SIGNPATH_ORGANIZATION_ID`: Your SignPath Organization ID GUID.
  - `SIGNPATH_PROJECT_SLUG`: `micgame-2`
  - `SIGNPATH_POLICY_SLUG`: `release-signing`
  - `SIGNPATH_ARTIFACT_SLUG`: `windows-zip`

Now, whenever you push a version tag (`git tag v1.0.0 && git push origin v1.0.0`) or trigger the workflow manually, GitHub Actions will build from source, sign `micgame3.exe` and `libonnx_pitch.windows.x86_64.dll` via SignPath's HSM, and attach the signed ZIP to your GitHub Release.
