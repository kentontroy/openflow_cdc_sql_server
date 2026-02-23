# Manual Steps: GitHub Registry Client Setup in OpenFlow/NiFi

## Prerequisites

1. **GitHub Repository** - Create or have access to a repository (e.g., `kentontroy/openflow_cdc_sql_server`)
2. **GitHub Personal Access Token (PAT)** - With `repo` or `public_repo` scope
3. **External Access Integration (SPCS only)** - EAI attached to your runtime that allows access to:
   - `api.github.com:443`
   - `github.com:443`

---

## Step 1: Create the GitHub Registry Client

1. Open the NiFi UI at your runtime URL (e.g., `https://of--sfpscogs-kdavis-aws-demo.snowflakecomputing.app/openflowquickstart/nifi/`)

2. Click the **hamburger menu** (≡) in the top-right corner

3. Select **Controller Settings**

4. Go to the **Registry Clients** tab

5. Click the **+** button to add a new registry client

6. Select **GitHubFlowRegistryClient** from the type dropdown

7. Configure the following properties:

   | Property | Value |
   |----------|-------|
   | Name | `openflow-cdc-sqlserver` (or your preferred name) |
   | GitHub API URL | `https://api.github.com/` |
   | Repository Owner | `kentontroy` |
   | Repository Name | `openflow_cdc_sql_server` |
   | Authentication Type | `Personal Access Token` |
   | Personal Access Token | `ghp_xxxxx...` (your PAT) |
   | Default Branch | `main` |
   | Parameter Context Values | `Ignore Changes` (recommended) |

8. Click **Add** to create the registry client

---

## Step 2: Create a Bucket (Folder) in GitHub

The registry client uses folders in your repository as "buckets" to organize flows.

1. Go to your GitHub repository in a browser

2. Click **Add file** → **Create new file**

3. In the filename field, type: `openflow/README.md`
   - This creates both the folder and a file (GitHub requires at least one file per folder)

4. Add some content like:
   ```markdown
   # OpenFlow Flows
   
   This folder contains NiFi flow definitions.
   ```

5. Click **Commit new file**

---

## Step 3: Commit a Process Group to Version Control

1. In the NiFi canvas, **right-click** on the Process Group you want to version (e.g., "Incremental Load")

2. Select **Version** → **Start version control**

3. In the dialog that appears:

   | Field | Value |
   |-------|-------|
   | Registry | Select your registry client (e.g., `openflow-cdc-sqlserver`) |
   | Bucket | Select the folder (e.g., `openflow`) |
   | Flow Name | Auto-populated from Process Group name |
   | Flow Description | Optional description |
   | Comments | e.g., "Initial commit of Incremental Load flow" |

4. Click **Save**

5. The Process Group will now show a **green checkmark** (✓) indicating it's under version control and up-to-date

---

## Step 4: Making Changes and Committing Updates

After the initial commit, when you modify the flow:

1. The Process Group will show a **gray asterisk** (*) indicating local modifications

2. To commit changes:
   - Right-click the Process Group
   - Select **Version** → **Commit local changes**
   - Enter a commit message describing your changes
   - Click **Save**

3. To discard changes and revert:
   - Right-click the Process Group
   - Select **Version** → **Revert local changes**
   - Confirm the revert

---

## Step 5: Viewing Version History

1. Right-click the versioned Process Group

2. Select **Version** → **Change version**

3. You'll see a list of all committed versions with:
   - Version number/commit SHA
   - Commit message
   - Timestamp

4. Select a version and click **Change** to roll back to that version

---

## Summary of UI Navigation

| Action | Menu Path |
|--------|-----------|
| Create Registry Client | ≡ → Controller Settings → Registry Clients → + |
| Start Version Control | Right-click PG → Version → Start version control |
| Commit Changes | Right-click PG → Version → Commit local changes |
| Revert Changes | Right-click PG → Version → Revert local changes |
| View/Change Versions | Right-click PG → Version → Change version |
| Stop Version Control | Right-click PG → Version → Stop version control |

---

## Version Control Status Indicators

| Icon | State | Meaning |
|------|-------|---------|
| ✓ (green) | UP_TO_DATE | Flow matches the committed version |
| * (gray) | LOCALLY_MODIFIED | Uncommitted local changes exist |
| ↓ (blue) | STALE | Newer version available in registry |
| ⚠ (yellow) | SYNC_FAILURE | Cannot communicate with registry |
