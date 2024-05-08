#!/bin/bash

# pfSense to AWS Ec2 image import
# Author: Marco Velotto
# Last update: 2024-05-03
#
# Put the image file in the image-input folder and follow istructions on screen


TIMESTAMP="$(date +%Y%M%d_%H%M%S)"
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
RANDSTR=$(tr -dc a-z0-9 </dev/urandom | head -c 8)

clear
echo -e "${GREEN}###########################################################"
echo -e "#               pfSense to AWS Ec2 Image import           #"
echo -e "###########################################################${NC}"
echo -e "\n"


PROFILE="default"
read -e -i "$PROFILE" -p "Please enter your AWS profile (enter for default): " input
PROFILE="${input:=default}"

BUCKET="pfsense-memstick"
read -e -i "$BUCKET" -p "Please enter your S3 Bucket Name (modify and press enter): " input
BUCKET="${input:=pfsense-memstick}"
echo -e "\n"

# print command for configuring the aws profile
echo "aws configure --profile ${PROFILE}"
aws configure --profile ${PROFILE}
echo -e "\n"


# create own specific json for roles

ROLEPOLICY="role-policy_${TIMESTAMP}.json"

cp ./aws/json/role-policy.json ${ROLEPOLICY}
sed -i s/BUCKET_PLACEHODLER/${BUCKET}/g ${ROLEPOLICY}

echo "Delete vmimport role and policy if exist. Errors is normal if they not exist..."
aws iam delete-role-policy --profile ${PROFILE} --role-name vmimport --policy-name vmimport
aws iam delete-role --profile ${PROFILE} --role-name vmimport

echo -e "\nCreate role and policy vmimport for your S3 Bucket..."
ROLEID=$(aws iam create-role --profile ${PROFILE} --role-name vmimport --assume-role-policy-document file://aws/json/trust-policy.json | tee /dev/null | grep RoleId | cut -d \" -f 4)

if [ -z "$ROLEID" ]
then
      echo -e "\n${RED}Error in role creation. Please verify IAM panel on your AWS console.${NC}"
      rm ${ROLEPOLICY}
      exit
else
      echo -e "Role created, RoleId: ${ROLEID}"
fi

aws iam put-role-policy --profile ${PROFILE} --role-name vmimport --policy-name vmimport --policy-document file://${ROLEPOLICY}
rm ${ROLEPOLICY}

echo "Wait 10 seconds to ensure role and policy propagation"

for i in {1..10..1}
do
   echo -ne "${RED}$i.${NC}"
   sleep 1
done

IMAGE="$(ls -1tr ./input-image/ | tail -n1)"

echo -e "\n${GREEN}Copy USB Installer image to S3 Bucket...${NC}"
aws s3 cp --profile ${PROFILE} ./input-image/${IMAGE} s3://${BUCKET}/${IMAGE}

# Create own specific json for import
IMPORTSNAPSHOT="import-snapshot_${TIMESTAMP}.json"

cp ./aws/json/import-snapshot.json ${IMPORTSNAPSHOT}
sed -i s/FORMAT_PLACEHODLER/RAW/g ${IMPORTSNAPSHOT}
sed -i s/BUCKET_PLACEHODLER/${BUCKET}/g ${IMPORTSNAPSHOT}
sed -i s/IMAGE_PLACEHODLER/${IMAGE}/g ${IMPORTSNAPSHOT}


echo -e "\nImport installer image as EC2 snapshot..."

# print output to stdout, capture ImporTaskId
IMPORTTASKID=$(aws ec2 --profile ${PROFILE} import-snapshot --disk-container file://${IMPORTSNAPSHOT} | tee /dev/null | grep ImportTaskId | cut -d \" -f 4)

if [ -z "$IMPORTTASKID" ]
then
      echo -e "\n${RED}Error in import task creation. Please verify permissions on your AWS console.${NC}"
	#rm ${IMPORTSNAPSHOT}
  	exit
else
      echo -e "Import task correctly created, ImportTaskId: ${IMPORTTASKID}"
      rm ${IMPORTSNAPSHOT}
fi

PROGRESS=0
echo -ne "Import progress:\n"

while [  $PROGRESS -lt 99 ]; do
    PROGRESS=$(aws ec2 --profile ${PROFILE} describe-import-snapshot-tasks --import-task-id ${IMPORTTASKID}| tee /dev/null | grep Progress | cut -d \" -f 4)
    if [ -z "$PROGRESS" ]
     then
       PROGRESS=100
     else
       printf "${RED}\r$PROGRESS%% "
       for i in {1..10..1}
        do
         echo -ne ">"
         sleep 0.5
        done
       printf "\r$PROGRESS%%            ${NC}"
     fi
done

STATUS=$(aws ec2 --profile ${PROFILE} describe-import-snapshot-tasks --import-task-id ${IMPORTTASKID}| tee /dev/null | grep Status | cut -d \" -f 4)

if [ ${STATUS} == "completed" ]
 then
   printf "\r${GREEN}$PROGRESS%%           "
   echo -e "\nSnapshot import completed successfully !${NC}"
   SNAPSHOTID=$(aws ec2 --profile ${PROFILE} describe-import-snapshot-tasks --import-task-id ${IMPORTTASKID}| tee /dev/null | grep SnapshotId | cut -d \" -f 4)
fi
echo -e "\nSnapshotID: ${SNAPSHOTID}"

AMINAME="ami-${RANDSTR}- pfSense 2.7.2 CE"
read -e -i "$AMINAME" -p "Please enter desidered name for AMI (modify and press enter): " input
AMINAME="${input:=ami-${RANDSTR}- pfSense 2.7.2 CE}"

AMIDESC="pfSense AMI from snapshot ${SNAPSHOTID}"
read -e -i "$AMIDESC" -p "Please enter a description for AMI (modify and press enter): " input
AMIDESC="${input:=AMI from snapshot ${SNAPSHOTID}}"
echo -e "\n"

# Create own specific json for AMI register
DEVICEMAPPING="device-mapping_${TIMESTAMP}.json"

cp ./aws/json/device-mapping.json ${DEVICEMAPPING}
sed -i s/SNAPSHOT_PLACEHOLDER/${SNAPSHOTID}/g ${DEVICEMAPPING}

IMAGEID=$(aws ec2 register-image --profile ${PROFILE} --name "${AMINAME}" --description "${AMIDESC}" \
 --architecture x86_64  --ena-support  --boot-mode uefi --root-device-name /dev/xvda \
 --virtualization-type hvm --block-device-mappings file://${DEVICEMAPPING} | tee /dev/null | grep ImageId | cut -d \" -f 4)

if [ -z "$IMAGEID" ]
then
      echo -e "\n${RED}Error in image registration. Please verify on your AWS console.${NC}"
else
      echo -e "\nSuccessfully created your pfSense AMI with Id: ${IMAGEID}"
      echo -e "${GREEN}Now you can configure and launch your pfSense instance !${NC}"
fi
rm ${DEVICEMAPPING}

exit
