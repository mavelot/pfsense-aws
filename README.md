# pfsense-aws
Script to create own Pfsense CE firewall in Aws Ec2 instances

This procedure was created to allow you to install a pfsense community edition machine on an AWS Ec2 instance.
Unlike other procedures that are based on the migration of a local virtual machine, my procedure allows you to directly install pfsense from the USB installation image with serial console output

All you need to do is download the USB memstick serial image from the NetGate site:
https://atxfiles.netgate.com/mirror/downloads/

Place the downloaded file in the input-image folder and run the sh or powershell script as appropriate.
The procedure will guide you, allowing you to create an AMI image in your AWS account, with which you can launch an EC2 instance according to your needs.
