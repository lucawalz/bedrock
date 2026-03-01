# Infrastructure Component Template

When adding new infrastructure components, follow this standardized structure:

## Directory Structure
```
component-name/
├── configmap.yaml         # Helm values as ConfigMap
├── helmrelease.yaml       # HelmRelease using valuesFrom
├── kustomization.yaml     # Kustomize resources
├── values.yaml           # Original values file (for reference)
└── ingress.yaml          # Optional: if component needs ingress
```

> **Note:** Namespace definitions are centralized in `namespaces/` at the cluster level.
> Add your namespace to `kubernetes/clusters/home/namespaces/` instead.

## ConfigMap Template
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: component-name-values
  namespace: component-namespace
data:
  values.yaml: |
    # Component Helm values
    # See: https://github.com/chart-repo/chart-name
    
    # Your values here...
```

## HelmRelease Template
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: component-name
  namespace: component-namespace
spec:
  interval: 30m
  chart:
    spec:
      chart: chart-name
      version: "x.x.x"
      sourceRef:
        kind: HelmRepository
        name: repo-name
        namespace: flux-system
  valuesFrom:
    - kind: ConfigMap
      name: component-name-values
      optional: true
  install:
    createNamespace: true
  upgrade:
    remediation:
      retries: 3
```

## Kustomization Template
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - configmap.yaml
  - helmrelease.yaml
  # Add other resources as needed
```

## Benefits of This Approach

1. **Maintainability**: Values are separated from HelmRelease definitions
2. **Consistency**: All components follow the same pattern
3. **Flexibility**: Easy to modify values without touching HelmRelease
4. **Version Control**: Clear diff when values change
5. **Reusability**: ConfigMaps can be referenced by multiple HelmReleases if needed