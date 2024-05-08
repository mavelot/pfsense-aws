# pfSense to AWS Ec2 image import
# Author: Marco Velotto
# Last update: 2024-05-03
#
# Put the image file in the image-input folder and follow istructions on screen

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$RandStr = -join ((48..57) + (97..122) | Get-Random -Count 8 | ForEach-Object {[char]$_})

Clear-Host

Write-Host "###########################################################" -ForegroundColor green
Write-Host "#               pfSense to AWS Ec2 Image import           #" -ForegroundColor green
Write-Host "###########################################################" -ForegroundColor green
Write-Host "`n"


$Profile = "default"
$Profile = Read-Host -Prompt "Please enter your AWS profile (enter for default value) [$($Profile)]"
if ([string]::IsNullOrEmpty($Profile)) { $Profile = "default" }

$Bucket = "pfsense-memstick"
$Bucket = Read-Host -Prompt "Please enter your S3 Bucket Name (enter for default value) [$($Bucket)]"
if ([string]::IsNullOrEmpty($Bucket)) { $Bucket = "pfsense-memstick" }
Write-Host ""

# Print command for configuring the aws profile
Write-Host "aws configure --profile $Profile"
aws configure --profile $Profile
Write-Host ""

# create own specific json for roles
$RolePolicy = "role-policy_$Timestamp.json"

Copy-Item -Path "./aws/json/role-policy.json" -Destination $RolePolicy
(Get-Content -Path $RolePolicy) -replace "BUCKET_PLACEHODLER", $Bucket | Set-Content -Path $RolePolicy

Write-Host "Delete vmimport role and policy if exist. Errors is normal if they not exist..."
aws iam delete-role-policy --profile $Profile --role-name vmimport --policy-name vmimport
aws iam delete-role --profile $Profile --role-name vmimport

Write-Host "Create role and policy vmimport for your S3 Bucket..."
$RoleId = (aws iam create-role --profile $Profile --role-name vmimport --assume-role-policy-document file://aws/json/trust-policy.json | ConvertFrom-Json).Role.RoleId

if ([string]::IsNullOrEmpty($RoleId)) {
    Write-Host "`nError in role creation. Please verify IAM panel on your AWS console."
    Remove-Item -Path $RolePolicy
    exit
}
else {
    Write-Host "Role created, RoleId: $RoleId"
}

aws iam put-role-policy --profile $Profile --role-name vmimport --policy-name vmimport --policy-document file://$RolePolicy
Remove-Item -Path $RolePolicy

Write-Host "Wait 10 seconds to ensure role and policy propagation"

for ($i = 1; $i -le 10; $i++) {
    Write-Host -NoNewline "$i." -ForegroundColor red
    Start-Sleep -Seconds 1
}

$Image = Get-ChildItem -Path "./input-image/" | Sort-Object -Property LastWriteTime | Select-Object -Last 1 | Select-Object -ExpandProperty Name

Write-Host "`nCopy USB Installer image to S3 Bucket..." -ForegroundColor green
aws s3 cp --profile $Profile "./input-image/$Image" "s3://$Bucket/$Image"

# Create own specific json for import
$ImportSnapshot = "import-snapshot_$Timestamp.json"

Copy-Item -Path "./aws/json/import-snapshot.json" -Destination $ImportSnapshot
(Get-Content -Path $ImportSnapshot) -replace "FORMAT_PLACEHODLER", "RAW" | Set-Content -Path $ImportSnapshot
(Get-Content -Path $ImportSnapshot) -replace "BUCKET_PLACEHODLER", $Bucket | Set-Content -Path $ImportSnapshot
(Get-Content -Path $ImportSnapshot) -replace "IMAGE_PLACEHODLER", $Image | Set-Content -Path $ImportSnapshot

Write-Host "`nImport installer image as EC2 snapshot..."

# Capture ImporTaskId
$ImportTaskId = (aws ec2 --profile $Profile import-snapshot --disk-container file://$ImportSnapshot | ConvertFrom-Json).ImportTaskId

if ([string]::IsNullOrEmpty($ImportTaskId)) {
    Write-Host "`nError in import task creation. Please verify permissions on your AWS console" -ForegroundColor red
    Remove-Item -Path $ImportSnapshot
    exit
}
else {
    Write-Host "Import task correctly created, ImportTaskId: $ImportTaskId"
    Remove-Item -Path $ImportSnapshot
}

# Follow Progress

$ImportProgress = 0
Write-Host "Import progress:"

while ($ImportProgress -lt 99) {
    $ImportProgress = (aws ec2 --profile $Profile describe-import-snapshot-tasks --import-task-id $ImportTaskId | ConvertFrom-Json).ImportSnapshotTasks[0].SnapshotTaskDetail.Progress
    if ([string]::IsNullOrEmpty($ImportProgress)) {
        $ImportProgress = 100
    }
    else {
        Write-Host -NoNewline "`r$ImportProgress% " -ForegroundColor Red
        for ($i = 1; $i -le 10; $i++) {
            Write-Host -NoNewline ">"  -ForegroundColor Red
            Start-Sleep -m 500
        }
        Write-Host -NoNewline "`r$ImportProgress%            " -ForegroundColor Red
    }
}

# Obtain final Status of Import Task

$Status = (aws ec2 --profile $Profile describe-import-snapshot-tasks --import-task-id $ImportTaskId | ConvertFrom-Json).ImportSnapshotTasks[0].SnapshotTaskDetail.Status

if ($Status -eq "completed") {
    Write-Host -NoNewline "`r$ImportProgress%" -ForegroundColor Green
    Write-Host "`nSnapshot import completed successfully !" -ForegroundColor Green
    $SnapshotId = (aws ec2 --profile $Profile describe-import-snapshot-tasks --import-task-id $ImportTaskId | ConvertFrom-Json).ImportSnapshotTasks[0].SnapshotTaskDetail.SnapshotId
}
Write-Host "SnapshotID: $SnapshotId"

$AmiName = "ami-$RandStr- pfSense 2.7.2 CE"
$AmiName = Read-Host -Prompt "Please enter desidered name for AMI (enter for default value) [$($AmiName)]"
if ([string]::IsNullOrEmpty($AmiName)) { $AmiName = "ami-$RandStr- pfSense 2.7.2 CE" }

$AmiDesc = "pfSense AMI from snapshot $SnapshotId"
$AmiDesc = Read-Host -Prompt "Please enter a description for AMI (enter for default value) [$($AmiDesc)]"
if ([string]::IsNullOrEmpty($AmiDesc)) { $AmiDesc = "AMI from snapshot $SnapshotId" }
Write-Host ""

# Create own specific json for AMI register
$DeviceMapping = "device-mapping_$Timestamp.json"

Copy-Item -Path "./aws/json/device-mapping.json" -Destination $DeviceMapping
(Get-Content -Path $DeviceMapping) -replace "SNAPSHOT_PLACEHOLDER", $SnapshotId | Set-Content -Path $DeviceMapping

$ImageId = (aws ec2 register-image --profile $Profile --name "$AmiName" --description "$AmiDesc" --architecture x86_64 --ena-support --boot-mode uefi --root-device-name /dev/xvda --virtualization-type hvm --block-device-mappings file://$DeviceMapping | ConvertFrom-Json).ImageId

if ([string]::IsNullOrEmpty($ImageId)) {
    Write-Host "`nError in image registration. Please verify on your AWS console." -ForegroundColor Red
}
else {
    Write-Host "`nSuccessfully created your pfSense AMI with Id: $ImageId" -ForegroundColor Green
    Write-Host "Now you can configure and launch your pfSense instance !" -ForegroundColor Green
}
Remove-Item -Path $DeviceMapping
