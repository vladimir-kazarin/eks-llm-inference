resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.10.3"
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 900

  values = [yamlencode({
    global  = { nodeSelector = { workload = "system" } }
    configs = { params = { "server.insecure" = true } } # ClusterIP + port-forward only
  })]

  depends_on = [module.eks]
}

# GitOps bridge: cluster facts Argo ApplicationSets template into Helm values.
resource "kubernetes_secret_v1" "argocd_in_cluster" {
  metadata {
    name      = "in-cluster"
    namespace = "argocd"
    labels    = { "argocd.argoproj.io/secret-type" = "cluster" }
    annotations = {
      cluster_name    = module.eks.cluster_name
      aws_region      = var.region
      vpc_id          = module.vpc.vpc_id
      allowed_cidrs   = join(",", var.allowed_cidrs)
      gitops_repo_url = var.gitops_repo_url
      gitops_revision = var.gitops_revision
    }
  }

  data = {
    name   = "in-cluster"
    server = "https://kubernetes.default.svc"
    config = jsonencode({ tlsClientConfig = { insecure = false } })
  }

  depends_on = [helm_release.argocd]
}

# Root app-of-apps via the argocd-apps chart, so Terraform never needs the Application CRD at plan time.
resource "helm_release" "argocd_root" {
  name       = "argocd-root"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.6"
  namespace  = "argocd"

  values = [yamlencode({
    applications = {
      root = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = var.gitops_revision
          path           = "gitops/apps"
        }
        destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
        syncPolicy  = { automated = { prune = true, selfHeal = true } }
      }
    }
  })]

  depends_on = [kubernetes_secret_v1.argocd_in_cluster]
}
