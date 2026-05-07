# Migrate Argo Applications

## Issue Statement

By default, deleting an `Application` manifest triggers a foreground deletion of all resources it manages. To move resources between `Application` without downtime, you must "orphan" the resources from the first `Application so they persist in the cluster, allowing the second app to "adopt" them.

Outline of Steps:

- Preparation: Disable pruning on the destination to prevent accidental deletions.
- Detachment (Non-Cascade): Delete the old `Application` via oc or UI while preserving resources.
- Migration: Update your Git repository manifests.
- Adoption: Create the new `Application` and sync.

## Steps in Detail

### 1. Preparation

Ensure the new Application is configured to be "gentle" during the handover. In your new Application YAML, it is safest to keep selfHeal off initially:

```yaml
spec:
  syncPolicy:
    automated:
      prune: false # Disable until transition is confirmed
      selfHeal: false
```

### 2. Detachment (The "Orphan" Move)

You need to delete the Application custom resource while leaving the actual Deployment/Service/etc. untouched.

**Option A**: Using oc (OpenShift CLI)
Run the delete command with the propagation policy set to orphan:
Bash

```bash
oc delete application <old-app-name> -n openshift-gitops --propagation-policy=Orphan
```

(Replace openshift-gitops with the namespace where your Argo CD is installed.)

**Option B**: Using the Argo CD UI

- Open the Argo CD Web Console and locate the old application.
- Click the Delete button.
- Crucial: In the confirmation dialog, locate the checkbox labeled "Non-cascade" and check it.
- Type the app name and confirm. The app will disappear from the UI, but your resources stay running.

### 3. Migration (Git)

Update your Git repository. Move the resource manifests from the path associated with the old app to the path for the new app. If you use a "Management" or "App-of-Apps" pattern, update the repoURL or path in your Application YAMLs.

### 4. Adoption (The Handover)

Apply the new Application YAML to the cluster:

```Bash
oc apply -f new-application.yaml
```

Finalizing in the UI:

- Open the new application in the UI. It will likely show as OutOfSync because it sees existing resources it doesn't "own" yet.
- Click Sync.
- If you get errors regarding "fields owned by another manager," use the Server-Side Apply option during sync (available in the Sync menu).
- Once the app is Healthy and Synced, you can re-enable prune: true and selfHeal: true in your YAML.
