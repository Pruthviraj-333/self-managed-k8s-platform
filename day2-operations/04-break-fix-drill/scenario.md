# Day-2 Runbook: Break-Fix Incident Simulation (NetworkPolicy Failure)

This operational drill simulates a real production incident: an improperly configured `NetworkPolicy` isolates backend microservices, causing gRPC connection timeouts and HTTP 500 errors. We systematically troubleshoot and resolve it using `kubectl describe`, `logs`, `events`, and ephemeral debug probes.

---

## 1. Incident Scenario: The Outage

A platform security engineer applies a baseline NetworkPolicy to enforce zero-trust isolation in the `boutique` namespace. However, the policy omits gRPC egress/ingress rules between `frontend` and the downstream microservices (`cartservice`, `productcatalogservice`).
The application immediately degrades: frontend throws **HTTP 500 Internal Server Error** when users attempt to view the store catalog.

---

## 2. Step-by-Step Incident Response & Troubleshooting Flow

### Step 1: Detect the Outage (Symptom Verification)
Check the frontend HTTP response:
```bash
INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -I -H "Host: boutique.k8s.local" "http://${INGRESS_IP}/"
```
*Symptom*: Returns `HTTP/1.1 500 Internal Server Error`.

### Step 2: Inspect Application Logs (`kubectl logs`)
Check the frontend application logs to pinpoint what failed:
```bash
kubectl logs -n boutique deployment/frontend --tail=40
```
*Observed Error*:
```
{"severity":"error","message":"could not retrieve products","error":"rpc error: code = Unavailable desc = connection error: desc = \"transport: Error while dialing: dial tcp 10.96.14.82:3550: i/o timeout\""}
```
**Insight**: The frontend cannot establish a TCP connection to `productcatalogservice` on port 3550 due to an I/O timeout.

### Step 3: Check Pod Health & Endpoints (`kubectl get`, `kubectl describe`)
Is `productcatalogservice` crashed or missing?
```bash
kubectl get pods -n boutique -l app=productcatalogservice
kubectl get endpoints productcatalogservice -n boutique
```
*Result*: The pod is `1/1 Running`, and the Service has valid backend pod IPs. The issue is strictly network connectivity.

### Step 4: Check Network Policies (`kubectl get netpol`)
Investigate if any firewall/CNI rules are active in the namespace:
```bash
kubectl get networkpolicies -n boutique
kubectl describe networkpolicy isolate-catalog -n boutique
```
*Root Cause Identified*: An active NetworkPolicy `isolate-catalog` has selected `app: productcatalogservice` but has an empty ingress rule that drops all incoming traffic from `app: frontend`!

### Step 5: Test Connectivity Using an In-Pod Diagnostic Probe
Run an interactive test from inside the frontend container:
```bash
kubectl exec -it -n boutique deployment/frontend -- nc -zv -w 2 productcatalogservice 3550 || true
```
*Output*: Connection timed out (packets dropped by Calico Netfilter/iptables rules).

### Step 6: Apply the Remediated NetworkPolicy
Apply `fix-network.yaml` allowing explicit ingress on TCP 3550 from pods with label `app: frontend`:
```bash
kubectl apply -f fix-network.yaml
```

### Step 7: Verify Resolution
```bash
curl -I -H "Host: boutique.k8s.local" "http://${INGRESS_IP}/"
```
*Result*: Returns `HTTP/1.1 200 OK`! Incident resolved.

---

## 3. Real Evidence Log & Terminal Transcript

```bash
$ curl -I -H "Host: boutique.k8s.local" "http://10.0.1.200/"
HTTP/1.1 500 Internal Server Error
Date: Fri, 18 Sep 2026 12:30:14 GMT
Content-Type: text/html; charset=utf-8

$ kubectl logs -n boutique deployment/frontend --tail=2
rpc error: code = Unavailable desc = connection error: desc = "transport: Error while dialing: dial tcp 10.96.14.82:3550: i/o timeout"

$ kubectl get netpol -n boutique
NAME              POD-SELECTOR                AGE
isolate-catalog   app=productcatalogservice   3m

$ kubectl apply -f fix-network.yaml
networkpolicy.networking.k8s.io/isolate-catalog configured

$ curl -I -H "Host: boutique.k8s.local" "http://10.0.1.200/"
HTTP/1.1 200 OK
Date: Fri, 18 Sep 2026 12:32:05 GMT
Content-Type: text/html; charset=utf-8
```
