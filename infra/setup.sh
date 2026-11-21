#!/usr/bin/env bash
# One-time setup of the Azure resources for form-dojo, using only the Azure CLI.
# Safe to re-run: each resource is checked before it is created.
#
# Usage:  az login   (and pick the right subscription), then:  bash infra/setup.sh
set -euo pipefail

# Git Bash on Windows rewrites arguments that start with "/" (like /subscriptions/...).
export MSYS_NO_PATHCONV=1

# ---- Settings (change these if you need to) ----
APP="form-dojo"
LOCATION="westeurope"
GITHUB_REPO="HackYourFutureBelgium/form-dojo"
GITHUB_BRANCH="main"

RESOURCE_GROUP="rg-$APP"
ENVIRONMENT="cae-$APP"
CONTAINER_APP="ca-$APP"
GITHUB_APP_NAME="github-$APP"

# ACR and storage account names are global and allow only lowercase letters and numbers,
# so a short suffix made from the subscription id keeps them unique.
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
SUFFIX="$(printf %s "$SUBSCRIPTION_ID" | md5sum | cut -c1-6)"
ACR_NAME="formdojo${SUFFIX}"
STORAGE_ACCOUNT="formdojo${SUFFIX}st"

echo "Subscription: $(az account show --query name -o tsv) ($SUBSCRIPTION_ID)"
echo "Location:     $LOCATION"
echo "Registry:     $ACR_NAME"
echo "Storage:      $STORAGE_ACCOUNT"
echo

# ---- Azure CLI extension and resource providers ----
az extension add --name containerapp --upgrade --yes >/dev/null
az provider register --namespace Microsoft.App --wait
az provider register --namespace Microsoft.OperationalInsights --wait

# ---- Resource group ----
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
RG_ID="$(az group show --name "$RESOURCE_GROUP" --query id -o tsv)"

# ---- Container registry (admin user off; the app pulls with its managed identity) ----
if ! az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az acr create --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" \
    --sku Basic --admin-enabled false --output none
fi
ACR_ID="$(az acr show --name "$ACR_NAME" --query id -o tsv)"

# ---- Storage account (the app creates the "submissions" table on first use) ----
if ! az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az storage account create --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" --sku Standard_LRS --kind StorageV2 \
    --allow-blob-public-access false --min-tls-version TLS1_2 --output none
fi
STORAGE_CONNECTION="$(az storage account show-connection-string \
  --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query connectionString -o tsv)"

# ---- Container Apps environment ----
if ! az containerapp env show --name "$ENVIRONMENT" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az containerapp env create --name "$ENVIRONMENT" --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" --output none
fi

# ---- Container App ----
# It starts with a placeholder image. The GitHub Actions workflow replaces it
# with the real image from ACR on the first merge to main.
if ! az containerapp show --name "$CONTAINER_APP" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az containerapp create --name "$CONTAINER_APP" --resource-group "$RESOURCE_GROUP" \
    --environment "$ENVIRONMENT" \
    --image mcr.microsoft.com/k8se/quickstart:latest \
    --target-port 8080 --ingress external \
    --min-replicas 0 --max-replicas 1 \
    --system-assigned \
    --secrets "storage-connection=$STORAGE_CONNECTION" \
    --env-vars "STORAGE_CONNECTION_STRING=secretref:storage-connection" \
    --output none
else
  az containerapp secret set --name "$CONTAINER_APP" --resource-group "$RESOURCE_GROUP" \
    --secrets "storage-connection=$STORAGE_CONNECTION" --output none
fi

# Let the app pull images from ACR with its managed identity.
APP_PRINCIPAL_ID="$(az containerapp show --name "$CONTAINER_APP" --resource-group "$RESOURCE_GROUP" \
  --query identity.principalId -o tsv)"

assign_role() { # assign_role <principal id> <role> <scope>
  local existing
  existing="$(az role assignment list --assignee "$1" --role "$2" --scope "$3" --query "length(@)" -o tsv)"
  if [ "$existing" = "0" ]; then
    az role assignment create --assignee-object-id "$1" --assignee-principal-type ServicePrincipal \
      --role "$2" --scope "$3" --output none
  fi
}

assign_role "$APP_PRINCIPAL_ID" AcrPull "$ACR_ID"
az containerapp registry set --name "$CONTAINER_APP" --resource-group "$RESOURCE_GROUP" \
  --server "$ACR_NAME.azurecr.io" --identity system --output none

# ---- GitHub Actions access with OIDC (no passwords or secrets stored in GitHub) ----
CLIENT_ID="$(az ad app list --display-name "$GITHUB_APP_NAME" --query "[0].appId" -o tsv)"
if [ -z "$CLIENT_ID" ]; then
  CLIENT_ID="$(az ad app create --display-name "$GITHUB_APP_NAME" --query appId -o tsv)"
fi
if [ -z "$(az ad sp list --filter "appId eq '$CLIENT_ID'" --query "[0].id" -o tsv)" ]; then
  az ad sp create --id "$CLIENT_ID" --output none
fi
GITHUB_PRINCIPAL_ID="$(az ad sp show --id "$CLIENT_ID" --query id -o tsv)"

# Only runs on the main branch of this repository may sign in.
CREDENTIAL_NAME="github-$GITHUB_BRANCH"
if [ -z "$(az ad app federated-credential list --id "$CLIENT_ID" \
      --query "[?name=='$CREDENTIAL_NAME'].name | [0]" -o tsv)" ]; then
  az ad app federated-credential create --id "$CLIENT_ID" --parameters "{
    \"name\": \"$CREDENTIAL_NAME\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:$GITHUB_REPO:ref:refs/heads/$GITHUB_BRANCH\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" --output none
fi

# Push images to ACR, and update the Container App (the resource group holds only this project).
assign_role "$GITHUB_PRINCIPAL_ID" AcrPush "$ACR_ID"
assign_role "$GITHUB_PRINCIPAL_ID" Contributor "$RG_ID"

# ---- Summary ----
APP_URL="$(az containerapp show --name "$CONTAINER_APP" --resource-group "$RESOURCE_GROUP" \
  --query properties.configuration.ingress.fqdn -o tsv)"

echo
echo "Done. Add these as GitHub variables on $GITHUB_REPO:"
echo "  AZURE_CLIENT_ID       = $CLIENT_ID"
echo "  AZURE_TENANT_ID       = $TENANT_ID"
echo "  AZURE_SUBSCRIPTION_ID = $SUBSCRIPTION_ID"
echo "  ACR_NAME              = $ACR_NAME"
echo "  RESOURCE_GROUP        = $RESOURCE_GROUP"
echo "  CONTAINER_APP         = $CONTAINER_APP"
echo
echo "Site URL (after the first deploy): https://$APP_URL"
