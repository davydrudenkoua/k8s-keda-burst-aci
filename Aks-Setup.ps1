function Add-KedaUserIdentity {
    param (
        [Parameter(Mandatory)][string] $Subscription,
        [Parameter(Mandatory)][string] $ResourceGroupName,
        [Parameter(Mandatory)][string] $Location,
        [Parameter(Mandatory)][string] $KedaUserAssignedIdentityName,
        [Parameter(Mandatory)][string] $ServiceBusNamespace
    )
    az identity create `
        --name $KedaUserAssignedIdentityName `
        --resource-group $ResourceGroupName `
        --location $Location

    $UserAssignedIdentityClientId = $(az identity show --resource-group $ResourceGroupName --name $KedaUserAssignedIdentityName --query 'clientId' -o tsv)
    $UserAssignedIdentityObjectId = $(az identity show --resource-group $ResourceGroupName --name $KedaUserAssignedIdentityName --query 'principalId' -o tsv)

    $ServiceBusId = $(az servicebus namespace show --name $ServiceBusNamespace --resource-group $ResourceGroupName --query "id" -o tsv)
    az role assignment create `
        --assignee $UserAssignedIdentityClientId `
        --role "Azure Service Bus Data Owner" `
        --assignee-object-id $UserAssignedIdentityObjectId `
        --scope $ServiceBusId

    return  @{
        ClientId = $UserAssignedIdentityClientId
        TenantId = $(az identity show --resource-group $ResourceGroupName --name $KedaUserAssignedIdentityName --query 'tenantId' -otsv)
    }
}

function Add-QueueScalerUserIdentity {
    param (
        [Parameter(Mandatory)][string] $Subscription,
        [Parameter(Mandatory)][string] $ResourceGroupName,
        [Parameter(Mandatory)][string] $Location,
        [Parameter(Mandatory)][string] $UserAssignedIdentityName,
        [Parameter(Mandatory)][string] $ServiceBusNamespace
    )
    az identity create `
        --name $UserAssignedIdentityName `
        --resource-group $ResourceGroupName `
        --location $Location

    $UserAssignedIdentityClientId = $(az identity show --resource-group $ResourceGroupName --name $UserAssignedIdentityName --query 'clientId' -o tsv)
    $UserAssignedIdentityObjectId = $(az identity show --resource-group $ResourceGroupName --name $UserAssignedIdentityName --query 'principalId' -o tsv)

    $ServiceBusId = $(az servicebus namespace show --name $ServiceBusNamespace --resource-group $ResourceGroupName --query "id" -o tsv)
    az role assignment create `
        --assignee $UserAssignedIdentityClientId `
        --role "Azure Service Bus Data Listener" `
        --assignee-object-id $UserAssignedIdentityObjectId `
        --scope $ServiceBusId

    return  @{
        ClientId = $UserAssignedIdentityClientId
        TenantId = $(az identity show --resource-group $ResourceGroupName --name $KedaUserAssignedIdentityName --query 'tenantId' -otsv)
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
#endregion

#region Creating AKS
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

kubectl create secret docker-registry queue-listener-registry-secret `
    --docker-server=https://index.docker.io/v1/ `
    --docker-username=$Env:DOCKER_USERNAME `
    --docker-password=$Env:DOCKER_PASSWORD

kubectl create namespace "keda"
#endregion

#region Keda Identity
$KedaIdentityParams = @{
    Subscription = $SubscriptionId
    ResourceGroupName = $ResourceGroupName
    Location = $Location
    KedaUserAssignedIdentityName = $KedaUserAssignedIdentityName
    $ServiceBusNamespace = $ScalingQueueNamespace
}
$KedaUserAssignedIdentityValues = Add-KedaUserIdentity @KedaIdentityParams

$AksOidcIssuer = $(
    az aks show `
        --name $ClusterName `
        --resource-group $ResourceGroupName `
        --query "oidcIssuerProfile.issuerUrl" `
        -o tsv
    )

az identity federated-credential create `
--name $KedaFederatedIdentityName `
--identity-name $KedaUserAssignedIdentityName `
--resource-group $ResourceGroupName `
--issuer $AksOidcIssuer `
--subject system:serviceaccount:keda:$KedaServiceAccountName `
--audience api://AzureADTokenExchange
#endregion

#region Queue Listener Identity
$QueueListenerIdentityParams = @{
    Subscription = $SubscriptionId
    ResourceGroupName = $ResourceGroupName
    Location = $Location
    UserAssignedIdentityName = $QueueListenerUserAssignedIdentityName
    $ServiceBusNamespace = $ScalingQueueNamespace
}
$QueueListenerUserAssignedIdentityValues = Add-QueueScalerUserIdentity @QueueListenerIdentityParams

az identity federated-credential create `
    --name $QueueListenerFederatedIdentityName `
    --identity-name $QueueListenerUserAssignedIdentityName `
    --resource-group $ResourceGroupName `
    --issuer $AksOidcIssuer `
    --subject system:serviceaccount:keda:$QueueListenerServiceAccountName `
    --audience api://AzureADTokenExchange
#endregion

#region Service Accounts
$QueueListenerServiceAccountTemplate = Get-Content -Path "k8s/service-accounts/queue-listener.service-account.yaml" -Raw
$QueueListenerServiceAccountTemplate = $QueueListenerServiceAccountTemplate -replace "{{QUEUE_LISTENER_USER_ASSIGNED_CLIENT_ID}}", $QueueListenerUserAssignedIdentityValues.ClientId
$KedaServiceAccountTemplate | kubectl apply -f


$KedaServiceAccountTemplate = Get-Content -Path "k8s/service-accounts/keda.service-account.yaml" -Raw
$KedaServiceAccountTemplate = $KedaServiceAccountTemplate -replace "{{KEDA_USER_ASSIGNED_CLIENT_ID}}", $KedaUserAssignedIdentityValues.ClientId
$KedaServiceAccountTemplate | kubectl apply -n "keda" -f
#endregion

#region Queue Listener Deployment
kubectl apply -f "k8s/deployments/queue-listener.deployment.yaml"
#endregion

#region Install Keda
helm repo add kedacore
helm repo update

helm install keda "kedacore/keda" --namespace "keda" `
    --set serviceAccount.create=false `
    --set serviceAccount.name=keda-operator `
    --set podIdentity.azureWorkload.enabled=true `
    --set podIdentity.azureWorkload.clientId=$KedaUserAssignedIdentityValues.ClientId `
    --set podIdentity.azureWorkload.tenantId=$KedaUserAssignedIdentityValues.TenantId
#endregion

#region Scaled Object
$ScaledObjectAccountTemplate = Get-Content -Path "k8s/keda/queue-listener.scaled-object.yaml" -Raw
$ScaledObjectAccountTemplate = $ScaledObjectAccountTemplate -replace "{{KEDA_USER_ASSIGNED_IDENTITY_CLIENT_ID}}", $KedaUserAssignedIdentityValues.ClientId
$ScaledObjectAccountTemplate = $ScaledObjectAccountTemplate -replace "{{SCALING_QUEUE_NAME}}", $ScalingQueueName
$ScaledObjectAccountTemplate = $ScaledObjectAccountTemplate -replace "{{SCALING_QUEUE_NAMESPACE}}", $ScalingQueueNamespace
$ScaledObjectAccountTemplate | kubectl apply -n "keda" -f
#endregion