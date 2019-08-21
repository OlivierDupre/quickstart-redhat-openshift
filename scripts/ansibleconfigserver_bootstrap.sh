#!/bin/bash -xe
echo "Running $(readlink -f $0)" >> /var/log/install.log

source ${P}

export INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)

echo "INSTANCE_ID=${INSTANCE_ID}" >> /var/log/install.log

qs_cloudwatch_install
systemctl stop awslogs || true
cat << EOF > /var/awslogs/etc/awslogs.conf
[general]
state_file = /var/awslogs/state/agent-state

[/var/log/messages]
buffer_duration = 5000
log_group_name = ${LOG_GROUP}
file = /var/log/messages
log_stream_name = ${INSTANCE_ID}/var/log/messages
initial_position = start_of_file
datetime_format = %b %d %H:%M:%S

[/var/log/ansible.log]
buffer_duration = 5000
log_group_name = ${LOG_GROUP}
file = /var/log/ansible.log
log_stream_name = ${INSTANCE_ID}/var/log/ansible.log
initial_position = start_of_file
datetime_format = %b %d %H:%M:%S

[/var/log/openshift-quickstart-scaling.log]
buffer_duration = 5000
log_group_name = ${LOG_GROUP}
file = /var/log/openshift-quickstart-scaling.log
log_stream_name = ${INSTANCE_ID}/var/log/openshift-quickstart-scaling.log
initial_position = start_of_file
datetime_format = %b %d %H:%M:%S
EOF

echo "awslogs configured" >> /var/log/install.log

# Reload the daemon
systemctl daemon-reload || true
systemctl start awslogs || true

echo "awslogs restarted" >> /var/log/install.log

if [ -f /quickstart/pre-install.sh ]
then
  /quickstart/pre-install.sh
fi

qs_enable_epel &> /var/log/userdata.qs_enable_epel.log

qs_retry_command 10 yum -y install jq
echo "Retrieving ${QS_S3URI}scripts/redhat_ose-register-${OCP_VERSION}.sh" >> /var/log/install.log
qs_retry_command 25 aws s3 cp ${QS_S3URI}scripts/redhat_ose-register-${OCP_VERSION}.sh ~/redhat_ose-register.sh
dos2unix ~/redhat_ose-register.sh
chmod 755 ~/redhat_ose-register.sh
echo "Registring RedHat OSE" >> /var/log/install.log
qs_retry_command 20 ~/redhat_ose-register.sh ${RH_CREDS_ARN}
echo "RedHat OSE registered" >> /var/log/install.log

qs_retry_command 10 yum -y install yum-versionlock ansible-${ANSIBLE_VERSION}

echo "Ansible installed" >> /var/log/install.log

yum versionlock add ansible
sed -i 's/#host_key_checking = False/host_key_checking = False/g' /etc/ansible/ansible.cfg
echo "Ansible configured" >> /var/log/install.log
yum repolist -v | grep OpenShift

qs_retry_command 10 pip install boto3 &> /var/log/userdata.boto3_install.log
mkdir -p /root/ose_scaling/aws_openshift_quickstart
mkdir -p /root/ose_scaling/bin
echo "Retrieving python scripts to /root/ose_scaling/aws_openshift_quickstart/" >> /var/log/install.log
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaling/aws_openshift_quickstart/__init__.py /root/ose_scaling/aws_openshift_quickstart/__init__.py
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaling/aws_openshift_quickstart/logger.py /root/ose_scaling/aws_openshift_quickstart/logger.py
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaling/aws_openshift_quickstart/scaler.py /root/ose_scaling/aws_openshift_quickstart/scaler.py
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaling/aws_openshift_quickstart/utils.py /root/ose_scaling/aws_openshift_quickstart/utils.py
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaling/bin/aws-ose-qs-scale /root/ose_scaling/bin/aws-ose-qs-scale
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaling/setup.py /root/ose_scaling/setup.py

qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/predefined_openshift_vars_${OCP_VERSION}.txt /tmp/openshift_inventory_predefined_vars

echo "Installing OSE scaling with pip" >> /var/log/install.log
pip install /root/ose_scaling

echo "Initiating CFN" >> /var/log/install.log
qs_retry_command 10 cfn-init -v --stack ${AWS_STACKNAME} --resource AnsibleConfigServer --configsets cfg_node_keys --region ${AWS_REGION}

echo openshift_master_cluster_hostname=${INTERNAL_MASTER_ELBDNSNAME} >> /tmp/openshift_inventory_userdata_vars
echo openshift_master_cluster_public_hostname=${MASTER_ELBDNSNAME} >> /tmp/openshift_inventory_userdata_vars
echo openshift_disable_check=memory_availability >> /tmp/openshift_inventory_userdata_vars

if [ "$(echo ${MASTER_ELBDNSNAME} | grep -c '\.elb\.amazonaws\.com')" == "0" ] ; then
    echo openshift_master_default_subdomain=${MASTER_ELBDNSNAME} >> /tmp/openshift_inventory_userdata_vars
fi

if [ "${ENABLE_HAWKULAR}" == "True" ] ; then
    if [ "$(echo ${MASTER_ELBDNSNAME} | grep -c '\.elb\.amazonaws\.com')" == "0" ] ; then
        echo openshift_metrics_hawkular_hostname=metrics.${MASTER_ELBDNSNAME} >> /tmp/openshift_inventory_userdata_vars
    else
        echo openshift_metrics_hawkular_hostname=metrics.router.default.svc.cluster.local >> /tmp/openshift_inventory_userdata_vars
    fi
    echo openshift_metrics_install_metrics=true >> /tmp/openshift_inventory_userdata_vars
    echo openshift_metrics_start_cluster=true >> /tmp/openshift_inventory_userdata_vars
    echo openshift_metrics_cassandra_storage_type=dynamic >> /tmp/openshift_inventory_userdata_vars
    qs_retry_command 10 yum install -y httpd-tools java-1.8.0-openjdk-headless
fi

if [ "${ENABLE_AUTOMATIONBROKER}" == "Disabled" ] ; then
    echo ansible_service_broker_install=false >> /tmp/openshift_inventory_userdata_vars
fi

if [ "${ENABLE_CLUSTERCONSOLE}" == "Disabled" ] && [ "${OCP_VERSION}" == "3.11" ] ; then
    echo openshift_console_install=false >> /tmp/openshift_inventory_userdata_vars
fi

echo openshift_hosted_registry_storage_s3_bucket=${REGISTRY_BUCKET} >> /tmp/openshift_inventory_userdata_vars
echo openshift_hosted_registry_storage_s3_region=${AWS_REGION} >> /tmp/openshift_inventory_userdata_vars

echo openshift_master_api_port=443 >> /tmp/openshift_inventory_userdata_vars
echo openshift_master_console_port=443 >> /tmp/openshift_inventory_userdata_vars

echo "Installing OS tools" >> /var/log/install.log
qs_retry_command 10 yum -y install vim wget git net-tools bind-utils iptables-services bridge-utils bash-completion kexec-tools sos psacct
# Workaround this not-a-bug https://bugzilla.redhat.com/show_bug.cgi?id=1187057
echo "Uninstalling urllib3" >> /var/log/install.log
pip uninstall -y urllib3
echo "Updating yum cache" >> /var/log/install.log
qs_retry_command 10 yum -y update
echo "Re-installing urllib3" >> /var/log/install.log
qs_retry_command 10 pip install urllib3
echo "Installing Openshift atomic excluders" >> /var/log/install.log
qs_retry_command 10 yum -y install atomic-openshift-excluder atomic-openshift-docker-excluder

cd /tmp
qs_retry_command 10 wget https://s3-us-west-1.amazonaws.com/amazon-ssm-us-west-1/latest/linux_amd64/amazon-ssm-agent.rpm
echo "Installing amazon-ssm-agent" >> /var/log/install.log
qs_retry_command 10 yum install -y ./amazon-ssm-agent.rpm
systemctl start amazon-ssm-agent
systemctl enable amazon-ssm-agent
rm ./amazon-ssm-agent.rpm
cd -

if [ "${GET_ANSIBLE_FROM_GIT}" == "True" ]; then
  CURRENT_PLAYBOOK_VERSION=https://github.com/openshift/openshift-ansible/archive/openshift-ansible-${OCP_ANSIBLE_RELEASE}.tar.gz
  curl  --retry 5  -Ls ${CURRENT_PLAYBOOK_VERSION} -o openshift-ansible.tar.gz
  tar -zxf openshift-ansible.tar.gz
  rm -rf /usr/share/ansible
  mkdir -p /usr/share/ansible
  echo "Installing openshift-ansible for Git" >> /var/log/install.log
  mv openshift-ansible-* /usr/share/ansible/openshift-ansible
else
  echo "Installing openshift-ansible" >> /var/log/install.log
  qs_retry_command 10 yum -y install openshift-ansible
fi

echo "Installing Openshift atomic excluders (once again?)" >> /var/log/install.log
qs_retry_command 10 yum -y install atomic-openshift-excluder atomic-openshift-docker-excluder
atomic-openshift-excluder unexclude

qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaleup_wrapper.yml  /usr/share/ansible/openshift-ansible/
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/bootstrap_wrapper.yml /usr/share/ansible/openshift-ansible/
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/playbooks/post_scaledown.yml /usr/share/ansible/openshift-ansible/
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/playbooks/post_scaleup.yml /usr/share/ansible/openshift-ansible/
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/playbooks/pre_scaleup.yml /usr/share/ansible/openshift-ansible/
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/playbooks/pre_scaledown.yml /usr/share/ansible/openshift-ansible/
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/playbooks/remove_node_from_etcd_cluster.yml /usr/share/ansible/openshift-ansible/
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/ansible_inventory.yaml /tmp/ansible_inventory.yaml # ODA


ASG_COUNT=3
if [ "${ENABLE_GLUSTERFS}" == "Enabled" ] ; then
    ASG_COUNT=4
fi
#while [ $(aws cloudformation describe-stack-events --stack-name ${AWS_STACKNAME} --region ${AWS_REGION} --query 'StackEvents[?ResourceStatus == `CREATE_COMPLETE` && ResourceType == `AWS::AutoScaling::AutoScalingGroup`].LogicalResourceId' --output json | grep -c 'OpenShift') -lt ${ASG_COUNT} ] ; do
#    echo "Waiting for ASG's to complete provisioning..."
#    sleep 120
#done

#export OPENSHIFTMASTERASG=$(aws cloudformation describe-stack-resources --stack-name ${AWS_STACKNAME} --region ${AWS_REGION} --query 'StackResources[? ResourceStatus == `CREATE_COMPLETE` && LogicalResourceId == `OpenShiftMasterASG`].PhysicalResourceId' --output text)

#qs_retry_command 10 aws autoscaling suspend-processes --auto-scaling-group-name ${OPENSHIFTMASTERASG} --scaling-processes HealthCheck --region ${AWS_REGION}
#qs_retry_command 10 aws autoscaling attach-load-balancer-target-groups --auto-scaling-group-name ${OPENSHIFTMASTERASG} --target-group-arns ${OPENSHIFTMASTERINTERNALTGARN} --region ${AWS_REGION}

#/bin/aws-ose-qs-scale --generate-initial-inventory --ocp-version ${OCP_VERSION} --write-hosts-to-tempfiles --debug
echo "Setting up ansible config" >> /var/log/install.log
cat /tmp/openshift_ansible_inventory* >> /tmp/openshift_inventory_userdata_vars || true
sed -i 's/#pipelining = False/pipelining = True/g' /etc/ansible/ansible.cfg
sed -i 's/#log_path/log_path/g' /etc/ansible/ansible.cfg
sed -i 's/#stdout_callback.*/stdout_callback = json/g' /etc/ansible/ansible.cfg
sed -i 's/#deprecation_warnings = True/deprecation_warnings = False/g' /etc/ansible/ansible.cfg

###### ODA ######

### dirty ? : should use instance name ?
  # {
  #   "Name": "tag:Name",
  #   "Values": ["openshift-etcd"]
  # },
  # {
  #   "Name": "tag:project",
  #   "Values": ["aforge"]
  # },
  # {
  #   "Name": "tag:role",
  #   "Values": ["etcd"]
  # }
      # EC2_INSTANCE=`aws ec2 describe-instances --region ${EC2_REGION}  --filters ${EC2_FILTERS} --query "Reservations[0].Instances[0].InstanceId" | jq -r '.'`
ETCD_INSTANCE_ID=$(aws ec2 describe-instances  --region=eu-central-1 --filters "Name=network-interface.addresses.private-ip-address,Values=10.2.1.10"  --query 'Reservations[*].Instances[*].[InstanceId]' | grep -v "\[" | grep -v "\]" | awk -F"\"" '{print $2}') 
MASTER_INSTANCE_ID=$(aws ec2 describe-instances  --region=eu-central-1 --filters "Name=network-interface.addresses.private-ip-address,Values=10.2.1.20"  --query 'Reservations[*].Instances[*].[InstanceId]' | grep -v "\[" | grep -v "\]" | awk -F"\"" '{print $2}')
NODE_INSTANCE_ID=$(aws ec2 describe-instances  --region=eu-central-1 --filters "Name=network-interface.addresses.private-ip-address,Values=10.2.1.30"  --query 'Reservations[*].Instances[*].[InstanceId]' | grep -v "\[" | grep -v "\]" | awk -F"\"" '{print $2}')

echo "Updating ansible inventory with ETCD_INSTANCE_ID=${ETCD_INSTANCE_ID}, MASTER_INSTANCE_ID=${MASTER_INSTANCE_ID}, NODE_INSTANCE_ID=${NODE_INSTANCE_ID}" >> /var/log/install.log

sed -i "s/ETCD_INSTANCE_ID/${ETCD_INSTANCE_ID}/g" /tmp/ansible_inventory.yaml
sed -i "s/MASTER_INSTANCE_ID/${MASTER_INSTANCE_ID}/g" /tmp/ansible_inventory.yaml
sed -i "s/NODE_INSTANCE_ID/${NODE_INSTANCE_ID}/g" /tmp/ansible_inventory.yaml
sed -i "s/INTERNAL_MASTER_ELBDNSNAME/${INTERNAL_MASTER_ELBDNSNAME}/g" /tmp/ansible_inventory.yaml
sed -i "s/MASTER_ELBDNSNAME/${MASTER_ELBDNSNAME}/g" /tmp/ansible_inventory.yaml
sed -i "s/QS_S3BUCKETNAME/${QS_S3BUCKETNAME}/g" /tmp/ansible_inventory.yaml
sed -i "s/REGISTRY_BUCKET/${REGISTRY_BUCKET}/g" /tmp/ansible_inventory.yaml
sed -i "s/AWS_REGION/${AWS_REGION}/g" /tmp/ansible_inventory.yaml


mv /etc/ansible/hosts /etc/ansible/hosts.bak || true
cp -f /tmp/ansible_inventory.yaml /etc/ansible/hosts

### dirty : should be a parameter... ## Required to install AWS Service Borker.
echo "ip-10-2-1-20.eu-central-1.compute.internal" > /tmp/openshift_initial_masters

###### /ODA ######

qs_retry_command 50 ansible -m ping all

echo "Ansible playing /usr/share/ansible/openshift-ansible/bootstrap_wrapper.yml" >> /var/log/install.log
ansible-playbook -i /tmp/ansible_inventory.yaml /usr/share/ansible/openshift-ansible/bootstrap_wrapper.yml > /var/log/bootstrap.log
echo "Ansible playing /usr/share/ansible/openshift-ansible/playbooks/prerequisites.yml" >> /var/log/install.log
ansible-playbook -i /tmp/ansible_inventory.yaml /usr/share/ansible/openshift-ansible/playbooks/prerequisites.yml >> /var/log/bootstrap.log
echo "Ansible playing /usr/share/ansible/openshift-ansible/playbooks/deploy_cluster.yml" >> /var/log/install.log
ansible-playbook -i /tmp/ansible_inventory.yaml /usr/share/ansible/openshift-ansible/playbooks/deploy_cluster.yml >> /var/log/bootstrap.log

#aws autoscaling resume-processes --auto-scaling-group-name ${OPENSHIFTMASTERASG} --scaling-processes HealthCheck --region ${AWS_REGION}

echo "Installing atomic-openshift-clients" >> /var/log/install.log
qs_retry_command 10 yum install -y atomic-openshift-clients
AWSSB_SETUP_HOST=$(head -n 1 /tmp/openshift_initial_masters)

set +x
echo "Getting OCP_PASS" >> /var/log/install.log
OCP_PASS=$(aws secretsmanager get-secret-value --secret-id  ${OCP_PASS_ARN} --region ${AWS_REGION} --query SecretString --output text)
echo "Setting OCP pass with OCP_PASS=${OCP_PASS}" >> /var/log/install.log
ansible masters -a "htpasswd -b /etc/origin/master/htpasswd admin ${OCP_PASS}"
echo "Defining cluster admin role" >> /var/log/install.log
ansible masters -a "oc adm policy add-cluster-role-to-user cluster-admin admin"
set -x

mkdir -p ~/.kube/
scp $AWSSB_SETUP_HOST:/etc/origin/master/admin.kubeconfig ~/.kube/config

if [ "${ENABLE_AWSSB}" == "Enabled" ]; then
    mkdir -p ~/aws_broker_install
    cd ~/aws_broker_install
    qs_retry_command 10 wget https://raw.githubusercontent.com/awslabs/aws-servicebroker/release-${SB_VERSION}/packaging/openshift/deploy.sh
    qs_retry_command 10 wget https://raw.githubusercontent.com/awslabs/aws-servicebroker/release-${SB_VERSION}/packaging/openshift/aws-servicebroker.yaml
    qs_retry_command 10 wget https://raw.githubusercontent.com/awslabs/aws-servicebroker/release-${SB_VERSION}/packaging/openshift/parameters.env
    chmod +x deploy.sh
    sed -i "s/TABLENAME=awssb/TABLENAME=${SB_TABLE}/" parameters.env
    sed -i "s/TARGETACCOUNTID=/TARGETACCOUNTID=${SB_ACCOUNTID}/" parameters.env
    sed -i "s/TARGETROLENAME=/TARGETROLENAME=${SB_ROLE}/" parameters.env
    sed -i "s/VPCID=/VPCID=${VPCID}/" parameters.env
    sed -i "s/^REGION=us-east-1$/REGION=${AWS_REGION}/" parameters.env
    export KUBECONFIG=/root/.kube/config
    ./deploy.sh
    cd ../
    rm -rf ./aws_broker_install/
fi

rm -rf /tmp/openshift_initial_*

if [ -f /quickstart/post-install.sh ]
then
  /quickstart/post-install.sh
fi

ETCD_INSTANCE_ID_2=$(aws ec2 describe-instances  --region=eu-central-1 --filters "Name=tag:Name,Values=openshift-etcd,Name=tag:project,Values=aforge,Name=tag:role,Values=etcd"  --query 'Reservations[0].Instances[0].InstanceId' | jq -r '.')  || true
echo "VERSION 2: ETCD_INSTANCE_ID_2=${ETCD_INSTANCE_ID_2}" >> /var/log/install.log