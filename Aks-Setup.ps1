function Add-UserIdentity {
    param (
        [Parameter(Mandatory)][string] $Subscription,
        [Parameter(Mandatory)][string] $ResourceGroupName,
        [Parameter(Mandatory)][string] $Location,
        [Parameter(Mandatory)][string] $UserAssignedIdentityName,
        [Parameter(Mandatory)][string] $ServiceBusNamespace,
        [Parameter(Mandatory)][string] $ServiceBusRole
    )
    az identity create `
        --name $UserAssignedIdentityName `
        --resource-group $ResourceGroupName `
        --location $Location

    $UserAssignedIdentityClientId = $(az identity show --resource-group $ResourceGroupName --name $UserAssignedIdentityName --query 'clientId' -o tsv)

    $ServiceBusId = $(az servicebus namespace show --name $ServiceBusNamespace --resource-group $ResourceGroupName --query "id" -o tsv)
    az role assignment create `
        --assignee $UserAssignedIdentityClientId `
        --role $ServiceBusRole `
        --scope $ServiceBusId

    return  @{
        ClientId = $UserAssignedIdentityClientId
        TenantId = $(az identity show --resource-group $ResourceGroupName --name $UserAssignedIdentityName --query 'tenantId' -otsv)
    }
}

#region Variables
$ResourceGroupName = "k8s-scaling-demo"
$ClusterName = "aks-scaling-demo"

$KedaFederatedIdentityName = "keda-federated-identity"
$QueueListenerFederatedIdentityName = "queue-listener-federated-identity"
$KedaUserAssignedIdentityName = "keda-user-assigned-identity"
$QueueListenerUserAssignedIdentityName="queue-listener-user-assigned-identity"
$QueueListenerServiceAccountName = "queue-listener"
$Location = $(az group show --name $ResourceGroupName --query "location" -o tsv)
$SubscriptionId = $(az account show --query "id" --output tsv)
$ScalingQueueName ="scaling-queue"
$ScalingQueueNamespace = "k8s-scaling-demo-sb-01"

$DockerUsername = $Env:DOCKER_USERNAME
$DockerPassword = $Env:DOCKER_PASSWORD
$DockerServer = "https://index.docker.io/v1/"
#endregion

#region Creating AKS
Write-Host "Creating AKS"
az aks create `
        --resource-group $ResourceGroupName `
        --name $ClusterName `
        --enable-oidc-issuer `
        --enable-workload-identity `
        --enable-keda `
        --generate-ssh-keys `
        --location $Location `
        --node-vm-size "Standard_B2s" `
        --node-count 1 `
        --tier "free"

az aks get-credentials --name $ClusterName --resource-group $ResourceGroupName

$AksOidcIssuer = $(
    az aks show `
        --name $ClusterName `
        --resource-group $ResourceGroupName `
        --query "oidcIssuerProfile.issuerUrl" `
        -o tsv
    )
Write-Host "AKS $ClusterName created and connected to kubectl"

kubectl create secret docker-registry queue-listener-registry-secret `
    --docker-server $DockerServer `
    --docker-username $DockerUsername `
    --docker-password $DockerPassword

Write-Host "secret for pulling queue-listener image created"
#endregion

#region Keda Identity
Write-Host "Creating user-assigned keda identity"
$KedaIdentityParams = @{
    Subscription = $SubscriptionId
    ResourceGroupName = $ResourceGroupName
    Location = $Location
    UserAssignedIdentityName = $KedaUserAssignedIdentityName
    ServiceBusNamespace = $ScalingQueueNamespace
    ServiceBusRole = "Azure Service Bus Data Owner"
}
$KedaUserAssignedIdentityValues = Add-UserIdentity @KedaIdentityParams

az identity federated-credential create `
--name $KedaFederatedIdentityName `
--identity-name $KedaUserAssignedIdentityName `
--resource-group $ResourceGroupName `
--issuer $AksOidcIssuer `
--subject system:serviceaccount:kube-system:keda-operator `
--audience api://AzureADTokenExchange
Write-Host "User-assigned keda identity created"
#endregion

#region Queue Listener Identity
Write-Host "Creating user-assigned queue-listener identity"
$QueueListenerIdentityParams = @{
    Subscription = $SubscriptionId
    ResourceGroupName = $ResourceGroupName
    Location = $Location
    UserAssignedIdentityName = $QueueListenerUserAssignedIdentityName
    ServiceBusNamespace = $ScalingQueueNamespace
    ServiceBusRole = "Azure Service Bus Data Receiver"
}
$QueueListenerUserAssignedIdentityValues = Add-UserIdentity @QueueListenerIdentityParams

az identity federated-credential create `
    --name $QueueListenerFederatedIdentityName `
    --identity-name $QueueListenerUserAssignedIdentityName `
    --resource-group $ResourceGroupName `
    --issuer $AksOidcIssuer `
    --subject system:serviceaccount:default:$QueueListenerServiceAccountName `
    --audience api://AzureADTokenExchange
Write-Host "User-assigned queue-listener identity created"
#endregion

#region Service Accounts
Write-Host "Creating queue-listener service account"
$QueueListenerServiceAccountTemplate = Get-Content -Path "k8s/service-accounts/queue-listener.service-account.yaml" -Raw
$QueueListenerServiceAccountTemplate = $QueueListenerServiceAccountTemplate -replace `
    "{{QUEUE_LISTENER_USER_ASSIGNED_CLIENT_ID}}", $QueueListenerUserAssignedIdentityValues.ClientId

$QueueListenerServiceAccountTemplate | kubectl apply -f -
Write-Host "Queue-listener service account created"
#endregion

#region Restarting keda-operator to enable workload identity
kubectl rollout restart deploy keda-operator -n kube-system
#endregion

#region queue-listener Deployment
Write-Host "Creating queue-listener deployment"
kubectl apply -f "k8s/deployments/queue-listener.deployment.yaml"
Write-Host "Queue-listener deployment created"
#endregion

#region Scaled Object
Write-Host "Deploying queue-listener scaled object"
$ScaledObjectAccountTemplate = Get-Content -Path "k8s/keda/queue-listener.scaled-object.yaml" -Raw
$ScaledObjectAccountTemplate = $ScaledObjectAccountTemplate -replace "{{KEDA_USER_ASSIGNED_IDENTITY_CLIENT_ID}}", $KedaUserAssignedIdentityValues.ClientId
$ScaledObjectAccountTemplate = $ScaledObjectAccountTemplate -replace "{{SCALING_QUEUE_NAME}}", $ScalingQueueName
$ScaledObjectAccountTemplate = $ScaledObjectAccountTemplate -replace "{{SCALING_QUEUE_NAMESPACE}}", $ScalingQueueNamespace
$ScaledObjectAccountTemplate | kubectl apply -f -
Write-Host "Queue-listener scaled object created"
#endregion