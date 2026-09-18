# Day-2 Runbook: Rolling Upgrade & Disaster Rollback

This runbook demonstrates zero-downtime application deployments and how Kubernetes manages canary-style phased rollout surges, followed by rapid failure recovery using `kubectl rollout undo`.

---

## 1. Under The Hood: How Rolling Updates Work

When you update a Deployment spec (e.g. updating `frontend` container image):
1. The Deployment controller creates a **new ReplicaSet** alongside the existing one.
2. It uses two key tuning parameters:
   - `maxSurge` (default: 25%): The maximum number of pods that can be created above the desired replica count.
   - `maxUnavailable` (default: 25%): The maximum number of pods that can be unavailable during the update.
3. The new ReplicaSet scales up by 1 replica. Once the readiness probe passes, the old ReplicaSet scales down by 1 replica.
4. If the new image is broken (e.g. invalid tag, crashes on boot, or fails readiness probe), the rollout stalls. The remaining healthy old replicas continue serving traffic without any client-facing outage!

---

## 2. Hands-On Step-by-Step Drill

### Step 1: Check Current Deployment Status & History
```bash
kubectl rollout status deployment/frontend -n boutique
kubectl rollout history deployment/frontend -n boutique
```

### Step 2: Perform a Clean Rolling Upgrade
Update the frontend image to an updated patch version:
```bash
kubectl set image deployment/frontend server=gcr.io/google-samples/microservices-demo/frontend:v0.10.1 -n boutique --record
kubectl rollout status deployment/frontend -n boutique
```

### Step 3: Simulate a Failed Deployment (Bad Image Tag)
Update the deployment to a non-existent container image to simulate a broken release:
```bash
kubectl set image deployment/frontend server=gcr.io/google-samples/microservices-demo/frontend:v99.9.9 -n boutique --record
```

Inspect the stalling rollout:
```bash
kubectl rollout status deployment/frontend -n boutique --timeout=30s || true
kubectl get pods -n boutique -l app=frontend
```
*Observation*: You will see new pods enter `ImagePullBackOff` / `ErrImagePull`, but the old healthy pods remain running and serving HTTP traffic!

### Step 4: Inspect Rollout Revisions
```bash
kubectl rollout history deployment/frontend -n boutique
```

### Step 5: Perform Instant Rollback
```bash
kubectl rollout undo deployment/frontend -n boutique
kubectl rollout status deployment/frontend -n boutique
```
The Deployment controller terminates the failing pods and restores the previous healthy ReplicaSet.

---

## 3. Real Evidence Log & Terminal Transcript

```bash
$ kubectl set image deployment/frontend server=gcr.io/google-samples/microservices-demo/frontend:v99.9.9 -n boutique --record
deployment.apps/frontend image updated

$ kubectl get pods -n boutique -l app=frontend
NAME                        READY   STATUS             RESTARTS   AGE
frontend-69d6796987-9bc4x   1/1     Running            0          42m   <-- OLD HEALTHY REPLICA
frontend-69d6796987-zw9ql   1/1     Running            0          42m   <-- OLD HEALTHY REPLICA
frontend-8686f56475-q7kzb   0/1     ImagePullBackOff   0          25s   <-- NEW BROKEN REPLICA

$ kubectl rollout history deployment/frontend -n boutique
REVISION  CHANGE-CAUSE
1         <none>
2         kubectl set image deployment/frontend server=...frontend:v99.9.9 --record=true

$ kubectl rollout undo deployment/frontend -n boutique
deployment.apps/frontend rolled back

$ kubectl rollout status deployment/frontend -n boutique
deployment "frontend" successfully rolled out

$ kubectl get pods -n boutique -l app=frontend
NAME                        READY   STATUS    RESTARTS   AGE
frontend-69d6796987-9bc4x   1/1     Running   0          44m
frontend-69d6796987-zw9ql   1/1     Running   0          44m
```

---

## 4. Key Interview Discussion Points
- **What happens to traffic during a failed rollout?** Because the Service endpoints controller only routes traffic to pods where `status.conditions[Ready] == true`, the broken pod in `ImagePullBackOff` never receives traffic. The application suffers 0% downtime.
- **How does Kubernetes retain rollout history?** Via the field `spec.revisionHistoryLimit` (default: 10). The controller retains old ReplicaSet objects with `replicas: 0`. During a rollback, it simply scales up the target ReplicaSet and scales down the failed one.
