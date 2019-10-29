# Dedicate node to pod

From https://docs.openshift.com/container-platform/3.11/admin_guide/scheduling/taints_tolerations.html

Note : this is the simpliest implementation possible.

## Taint node
```bash
oc adm taint nodes ip-10-2-1-32.eu-central-1.compute.internal dedicated=jenkins:NoSchedule
```


## Add toleration to DC
OCP doc explains how to add "tolerations" to pod. However, as our pods are recreated each day, this method is not suitable and we need to patch the DC.

```bash
oc patch dc dc-jenkins -p '{"spec":{"template":{"spec":{"tolerations":[{"effect":"NoSchedule","key":"dedicated","operator": "Equal","value": "jenkins"}]}}}}'
```