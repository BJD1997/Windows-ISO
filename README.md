# Auto-Serviced Windows 11 ISO

Keeps an up-to-date, CU-patched Windows 11 ISO available at all times.

Every week the pipeline:

1. Downloads the latest Windows 11 ISO (via **Fido**, which resolves the
   official Microsoft link).
2. Scrapes the **Microsoft Update Catalog** for the newest Cumulative Update.
3. Extracts the ISO, converting `install.esd` → `install.wim` if needed.
4. Mounts the WIM, applies the CU with **DISM**, cleans the component store,
   commits.
5. Rebuilds a bootable dual BIOS/UEFI ISO with **oscdimg**.
6. Uploads the ISO to a **private Azure Blob container**.
7. Cuts a GitHub **Release** containing only a pointer + SHA256 — never the ISO.

---

## The architecture, and why

This layout exists to satisfy three constraints that pull against each other.

| Constraint | Consequence |
|---|---|
| Windows runner minutes are expensive on private repos (2x multiplier, ~1,000/mo) | **Repo is public** → unlimited free minutes |
| Redistributing a modified Windows ISO publicly is not permitted | **ISO goes to a private Blob container**, not the repo |
| GitHub release assets cap at 2 GiB; an ISO is ~5 GB | **Release holds a manifest, not the image** |

Net result: the *code* is public (which is fine — it's just a script), the
*image* is private (which is required), and the build is free.

---

## Setup

### 1. Storage

Create a storage account and a container. **Set the container's public access
level to `Private (no anonymous access)`.**

> If you leave it on "Blob (anonymous read)", the ISO becomes a public URL and
> you have undone the entire reason it isn't in the repo.

### 2. Secrets

Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `AZURE_STORAGE_ACCOUNT` | storage account name |
| `AZURE_STORAGE_KEY` | account access key |
| `AZURE_CONTAINER` | container name |

### 3. Run it

Actions → *Build Serviced Windows 11 ISO* → **Run workflow**. Overrides are
available for release, edition, and CU build family. After that the weekly cron
takes over.

---

## ⚠️ Public repo: the one rule

**Never add a `pull_request` or `pull_request_target` trigger to this workflow.**

Anyone can open a PR against a public repo. GitHub withholds secrets from fork
PRs — but `pull_request_target` runs *with* secrets in the base-repo context, so
a malicious PR that edits the workflow could read `AZURE_STORAGE_KEY`.

The workflow triggers on `schedule` and `workflow_dispatch` only.
`workflow_dispatch` requires write access. Keep it that way.

*(Hardening upgrade: swap the account key for **OIDC federated credentials** so
no long-lived secret lives in the repo at all. More setup, strictly better.)*

---

## Retrieving an ISO

Open the latest Release. It gives you the blob path and the expected SHA256.

```powershell
az storage blob download `
  --account-name <account> `
  --container-name <container> `
  --name "iso/Windows11_25H2_Pro_x64_2026-07-14.iso" `
  --file ".\Windows11.iso" `
  --auth-mode login

# verify before you deploy it
(Get-FileHash .\Windows11.iso -Algorithm SHA256).Hash
```

---

## Things that will bite you

**`runs-on: windows-2022` is deliberate.** `windows-latest` (Server 2025)
removed the `D:` drive and leaves ~33 GB free on `C:` — nowhere near enough for
ISO + extraction + WIM servicing. `windows-2022` still has `D:` with ~140 GB.
All heavy work happens there. Do not "helpfully" bump this to `windows-latest`.

**The ADK download link goes stale.** `oscdimg.exe` isn't preinstalled, so the
workflow installs the ADK Deployment Tools feature via a Microsoft `fwlink`.
That link changes with each ADK release. If the install step fails, fetch the
current ADK link and swap it in.

**install.esd vs install.wim.** Consumer ISOs ship `install.esd`, which DISM
can't mount for servicing. The script exports *only your target edition* to a
fresh `install.wim` — so the output ISO is single-edition (and smaller). If the
export fails, it prints the edition names found in the ESD so you can fix
`-ImageEdition`.

**DISM is slow.** Applying a full CU offline takes 30–60+ minutes. That's
normal, not a hang. Job timeout is 360 min.

**`/ResetBase` is in there.** The component cleanup step shrinks the image but
blocks uninstalling the applied CU later. Drop that line from
`Build-ServicedISO.ps1` if you want it removable.

**Blob egress isn't free.** Unlike some object stores, Azure charges for
outbound data beyond the monthly free allowance. A 5 GB ISO pulled by a dozen
techs adds up — check current pricing if this gets wide use.

---

## Tuning

| Release | `build` input |
|---|---|
| 25H2 | `26200` |
| 24H2 | `26100` |

Set `image_edition` to match (e.g. `Windows 11 Enterprise`).

`KEEP_LAST` in the workflow env controls how many ISOs are retained in the
container before old ones are pruned.

---

## Layout

```
.
├── .github/workflows/build-serviced-iso.yml   # the pipeline
├── scripts/Build-ServicedISO.ps1              # all servicing logic
└── README.md
```

`Build-ServicedISO.ps1` also runs standalone (`-CiSystem none`) if you want to
build locally on a machine with the ADK installed.
