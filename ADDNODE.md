# Add new node

## Create EC2

In EC2 Dashboard, Create on "Launch Instance".
 Search for "ami-09de4a4c670389e4b", and select "Community AMIs". There should be be only 1 AMI : "RHEL-7.6_HVM_GA-20190128-x86_64-0-Hourly2-GP2 - ami-09de4a4c670389e4b"
 Select it and go to next page.

### FLAVOR:
Select the desired flavor (recommended : t2.2xlarge : 8CPUs, 32GB RAM) and go to the next page

### NETWORK:
Network : AForge VPC
Subnet : private Subnet 1A
IAM Role : aforge-OpenshiftStack...
Network Interface -> Primary IP -> 10.2.1.3X

### STORAGE:
Root -> 80GB -> NO delete on termination
EBS -> /dev/sdb -> 110GB -> NO delete on termination

### SECURITY:
SecGroup : Openshift Node Sec group

### TAGS :
AutoStart true
AutoStop true
Name openshift-nodeX
kubernetes.io/cluster/aforge owned
project aforge
roles nodes
scope aws     


&nbsp;
&nbsp;
&nbsp;
## OCP installation

### PREQ
You need to be root for this chapter on the node instance:
```bash
sudo su -
```
&nbsp;
### Variables 
Export The following variables (BEWARE OF FIRST_INSTALL param!!):
```bash
#export QSLOCATION=https://aforge-aws-templates.s3.amazonaws.com/aforge/
export FIRST_INSTALL=no
export ENABLE_HAWKULAR=True
export GET_ANSIBLE_FROM_GIT=False
export OCP_ANSIBLE_RELEASE=3.11.115-1
export ANSIBLE_VERSION=2.6.6
export RH_USER=olivier.dal-pan@capgemini.com
export RH_POOLID=8a85f9996a6ee342016a92b055e15e16
export QS_S3BUCKETNAME=aforge-aws-templates
export ENABLE_AWSSB=Enabled
export VPCID=vpc-04fe8c470f4fc5072
export ENABLE_AUTOMATIONBROKER=Enabled
export ENABLE_CLUSTERCONSOLE=Enabled
export ENABLE_GLUSTERFS=Disabled
export SB_ROLE=poc-aforge-OpenShiftStack-NS4958-ServiceBrokerRole-12W7TYKWE3PNV
export SB_TABLE=poc-aforge-OpenShiftStack-NS4958C83RP-ServiceBrokerTable-CKAH36VEGX9L
export SB_VERSION=v1.0.0-beta.3
export SB_ACCOUNTID=594574517065
export P=/quickstart-linux-utilities/quickstart-cfn-tools.source
export QS_S3URI=s3://aforge/openshift-stack/
export LOG_GROUP=aforge-OpenShiftStack-1F85GV6LQ4C2-OpenshiftLogGroup-1SEFGMPAZVAE6
export OCP_VERSION=3.11
export AWS_REGION=eu-central-1
export RH_CREDS_ARN=arn:aws:secretsmanager:eu-central-1:175914515715:secret:RedhatSubscriptionSecret-Zdrust06uiQi-WAq1Fd
export AWS_STACKNAME=aforge-OpenShiftStack-1F85GV6LQ4C2
export INSTANCE_NAME=OpenShiftNode4EC2
export OPENSHIFTMASTERINTERNALELB=arn:aws:elasticloadbalancing:eu-central-1:175914515715:loadbalancer/aforge-Op-OpenShif-10Z72DHJMTJ56
export INTERNAL_MASTER_ELBDNSNAME=aforge-Op-OpenShif-10Z72DHJMTJ56-1822595569.eu-central-1.elb.amazonaws.com
export MASTER_ELBDNSNAME=aforge-ads.com
export CONTAINERACCESSELB=aforge-Op-Containe-E03DHX86NI63
export OCP_PASS_ARN=arn:aws:secretsmanager:eu-central-1:175914515715:secret:OpenShiftPasswordSecret-joqNDktNI2Zm-r1Ta1Y
export INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
export REGISTRY_BUCKET=aforge-openshiftstack-1f85gv6lq4c2-registrybucket-xa2tt0vdcxd4
```

&nbsp;
### Node installation
```bash
yum install -y git dos2unix && cd / && git clone https://github.com/aws-quickstart/quickstart-linux-utilities.git && export P=/quickstart-linux-utilities/quickstart-cfn-tools.source && source $P
(...)
[INFO] Dependencies Met!
```



```bash
qs_bootstrap_pip || qs_err " pip bootstrap failed "
(...)
Successfully installed pip-19.2.3 wheel-0.33.6
```
```bash
qs_aws-cfn-bootstrap || qs_err " cfn bootstrap failed "
(...)
Successfully installed aws-cfn-bootstrap-1.4 lockfile-0.12.2 pystache-0.5.4 python-daemon-1.6.1
[FOUND] (cfn-signal)
```

```bash
pip install awscli  &> /var/log/userdata.awscli_install.log || qs_err " awscli install failed "
```

```bash
aws s3 cp s3://aforge/openshift-stack/scripts/bootstrap.sh ./bootstrap.sh && dos2unix bootstrap.sh && chmod +x bootstrap.sh
download: s3://aforge/openshift-stack/scripts/bootstrap.sh to ./bootstrap.sh 
```

Launch the bootstrap.sh script.
```bash
/bootstrap.sh
```  


Latest Ansible scripts requires a recent Linux Kernel to be installed on the nodes to provision :
```bash
yum update kernel && reboot
```  


&nbsp;
### OCP Servers prep
Ansible scripts need to connect as root on all OCP servers (ETCD, MASTERS, NODES). For each one, proceed as follows :
```bash
sudo su -
cd ~/.ssh/ && cp authorized_keys authorized_keys.bak && sed -i "s/command=\".*\"//g" authorized_keys && cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak && sed -i "s/\#PermitRootLogin.*/PermitRootLogin yes/g" /etc/ssh/sshd_config

systemctl restart sshd
```

The /etc/hosts file must only include the localhost resolution directives:
`
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
`
If other lines are present, back up the file and remove the undesired lines






&nbsp;
### Ansible scripts on ansible-configserver instance

Retrieve the ansible inventory:
```bash
aws s3 cp s3://aforge/openshift-stack/scripts/ansible_inventory.yaml /tmp/ansible_inventory.yaml
dos2unix /tmp/ansible_inventory.yaml
```


Add the node as a "new_nodes" item:
```yaml
    new_nodes:
      hosts:
        ip-10-2-1-31.eu-central-1.compute.internal:
          instance_id: NODE_NEW_INSTANCE_ID
          openshift_node_group_name: node-config-compute-infra
```
**ADD ALL EXISTING NODES INTO THE "nodes"  SECTION.**
Provision it: (beware of the IP for the NEW_NODE_INSTANCE_ID)
```bash
export ETCD_INSTANCE_ID=$(aws ec2 describe-instances  --region=eu-central-1 --filters "Name=network-interface.addresses.private-ip-address,Values=10.2.1.10"  --query 'Reservations[*].Instances[*].[InstanceId]' | grep -v "\[" | grep -v "\]" | awk -F"\"" '{print $2}') 
export MASTER_INSTANCE_ID=$(aws ec2 describe-instances  --region=eu-central-1 --filters "Name=network-interface.addresses.private-ip-address,Values=10.2.1.20"  --query 'Reservations[*].Instances[*].[InstanceId]' | grep -v "\[" | grep -v "\]" | awk -F"\"" '{print $2}')
export NODE_INSTANCE_ID=$(aws ec2 describe-instances  --region=eu-central-1 --filters "Name=network-interface.addresses.private-ip-address,Values=10.2.1.30"  --query 'Reservations[*].Instances[*].[InstanceId]' | grep -v "\[" | grep -v "\]" | awk -F"\"" '{print $2}')
export NODE2_INSTANCE_ID=$(aws ec2 describe-instances  --region=eu-central-1 --filters "Name=network-interface.addresses.private-ip-address,Values=10.2.1.31"  --query 'Reservations[*].Instances[*].[InstanceId]' | grep -v "\[" | grep -v "\]" | awk -F"\"" '{print $2}')
export NODE3_INSTANCE_ID=$(aws ec2 describe-instances  --region=eu-central-1 --filters "Name=network-interface.addresses.private-ip-address,Values=10.2.1.32"  --query 'Reservations[*].Instances[*].[InstanceId]' | grep -v "\[" | grep -v "\]" | awk -F"\"" '{print $2}')
export NODE_NEW_INSTANCE_ID=$(aws ec2 describe-instances  --region=eu-central-1 --filters "Name=network-interface.addresses.private-ip-address,Values=10.2.1.32"  --query 'Reservations[*].Instances[*].[InstanceId]' | grep -v "\[" | grep -v "\]" | awk -F"\"" '{print $2}')

sed -i "s/ETCD_INSTANCE_ID/${ETCD_INSTANCE_ID}/g" /tmp/ansible_inventory.yaml
sed -i "s/MASTER_INSTANCE_ID/${MASTER_INSTANCE_ID}/g" /tmp/ansible_inventory.yaml
sed -i "s/NODE_INSTANCE_ID/${NODE_INSTANCE_ID}/g" /tmp/ansible_inventory.yaml
sed -i "s/NODE2_INSTANCE_ID/${NODE2_INSTANCE_ID}/g" /tmp/ansible_inventory.yaml
sed -i "s/NODE3_INSTANCE_ID/${NODE3_INSTANCE_ID}/g" /tmp/ansible_inventory.yaml
sed -i "s/INTERNAL_MASTER_ELBDNSNAME/${INTERNAL_MASTER_ELBDNSNAME}/g" /tmp/ansible_inventory.yaml
sed -i "s/NODE_NEW_INSTANCE_ID/${NODE_NEW_INSTANCE_ID}/g" /tmp/ansible_inventory.yaml


sed -i "s/REGISTRY_BUCKET/${REGISTRY_BUCKET}/g" /tmp/ansible_inventory.yaml
sed -i "s/AWS_REGION/${AWS_REGION}/g" /tmp/ansible_inventory.yaml
```

Add the node as a "new_nodes" item (beware of the hostname):
```yaml
    new_nodes:
      hosts:
        ip-10-2-1-31.eu-central-1.compute.internal:
          instance_id: ${NEW_NODE_INSTANCE_ID}
          openshift_node_group_name: node-config-compute-infra
```

cp -f /tmp/ansible_inventory.yaml /etc/ansible/hosts


Launch playbook:
``` 
ansible-playbook -i /tmp/ansible_inventory.yaml /usr/share/ansible/openshift-ansible/playbooks/openshift-node/scaleup.yml
(...)
INSTALLER STATUS **********************************************************************************************************************************************
Initialization  : Complete (0:00:38)
Node Join       : Complete (0:03:12)
```




&nbsp;
### Restore configuration on OCP servers
Comment the "PermitRootLogin yes" in /etc/ssh/sshd_config and restart sshd Service :
```bash
```bash
cd ~/.ssh/ && rm authorized_keys && mv authorized_keys.bak authorized_keys && rm /etc/ssh/sshd_config && mv /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
systemctl restart sshd
```

If /etc/hosts was modified, restore the backup.



### Update LB Configuration AWS
The new node needs to put behind the AWS LB :
EC2 -> LOAD BALANCING -> Load Balancers
Select the "aforge-Op-Containe-XXXXXXXXX", go to the "Instances" tab and click "Edit Instances".
Make sure to select all nodes and click "Save".
Wait 10sec and refresh the page. In the "Instances" tab you should see all nodes with status "In Service".





### Scale up the OpenShift router

As an OpenShift "cluster:admin" user, 

oc scale dc/router --replicas=0 -n default && oc scale dc/router --replicas=1 -n default



### Install node_exporter
Launch the following script as root :
```bash
#!/bin/bash
export NODE_EXP_VERSION=0.18.1
useradd -m -s /bin/bash prometheus
# (or adduser --disabled-password --gecos "" prometheus)

# Download node_exporter release from original repo
curl -L -O  https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXP_VERSION}/node_exporter-${NODE_EXP_VERSION}.linux-amd64.tar.gz

tar -xzvf node_exporter-${NODE_EXP_VERSION}.linux-amd64.tar.gz
mv node_exporter-${NODE_EXP_VERSION}.linux-amd64 /home/prometheus/node_exporter
rm node_exporter-${NODE_EXP_VERSION}.linux-amd64.tar.gz
chown -R prometheus:prometheus /home/prometheus/node_exporter

# Add node_exporter as systemd service
tee -a /etc/systemd/system/node_exporter.service << END
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target
[Service]
User=prometheus
ExecStart=/home/prometheus/node_exporter/node_exporter --web.listen-address=:9102
[Install]
WantedBy=default.target
END

systemctl daemon-reload
systemctl start node_exporter
systemctl enable node_exporter
```

Then Go into OCP, namespace "prometheus", and edit the "prometheus-cm" configMap to add the new target. Once done, redeploy prometheus.



