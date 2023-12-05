#!/usr/bin/env bash

default_alamedanotificationchannels="default"
default_alamedanotificationtopics="default"

check_version()
{
    openshift_minor_version=`oc version 2>/dev/null|grep "oc v"|cut -d '.' -f2`
}

webhook_reminder()
{
    check_version
    if [ "$openshift_minor_version" != "" ];then
        echo -e "$(tput setaf 9)Note!$(tput setaf 10) Below $(tput setaf 9)two admission plugins $(tput setaf 10)needed to be enabled on $(tput setaf 9)every master nodes $(tput setaf 10)to let VPA Execution and Email Notifier working properly."
        echo -e "$(tput setaf 6)1. ValidatingAdmissionWebhook 2. MutatingAdmissionWebhook$(tput sgr 0)"
        echo -e "Steps: (On every master nodes)"
        echo -e "A. Edit /etc/origin/master/master-config.yaml"
        echo -e "B. Insert following content after admissionConfig:pluginConfig:"
        echo -e "$(tput setaf 3)    ValidatingAdmissionWebhook:"
        echo -e "      configuration:"
        echo -e "        kind: DefaultAdmissionConfig"
        echo -e "        apiVersion: v1"
        echo -e "        disable: false"
        echo -e "    MutatingAdmissionWebhook:"
        echo -e "      configuration:"
        echo -e "        kind: DefaultAdmissionConfig"
        echo -e "        apiVersion: v1"
        echo -e "        disable: false"
        echo -e "$(tput sgr 0)C. Save the file."
        echo -e "D. Execute below commands to restart OpenShift api and controller:"
        echo -e "$(tput setaf 6)1. master-restart api 2. master-restart controllers$(tput sgr 0)"
    fi
}

webhook_mutation_checker()
{
    crname=$1
    yamlfile=$2
    cat > ${yamlfile} << __EOF__
apiVersion: notifying.containers.ai/v1alpha1
kind: AlamedaNotificationChannel
metadata:
  annotations: null
  name: ${crname}
spec:
  type: email
  email:
    server: ""
    port: 0
    from: ""
    username: ""
    password: ""
    encryption: tls
__EOF__

    echo "Doing webhook mutation test..."
    kubectl apply -f ${yamlfile}
    if [ "$?" -ne "0" ]; then
        echo -e "$(tput setaf 1)Failed to apply webhook mutation testing CR$(tput sgr 0)"
        return ${ret}
    fi

    kubectl get alamedanotificationchannels ${crname} -o 'jsonpath={.metadata.annotations.notifying\.containers\.ai\/webhook-mutation}' 2>/dev/null | grep -q 'ok'
    if [ "$?" -eq "0" ]; then
        echo "Detection result: webhook mutation is enabled"
        return 0
    else
        echo "Detection result: webhook mutation is disabled"
        return 14
    fi
}

webhook_validation_checker()
{
    crname=$1
    yamlfile=$2
    if [ ! -f ${yamlfile} ]; then
        echo "Error! Test yaml file ${yamlfile} doesn't exist."
        return 2
    fi
    sed -i 's/port: 0/port: 1/g' ${yamlfile}

    echo "Doing the webhook validation test..."
    kubectl apply -f ${yamlfile}
    if [ "$?" -ne "0" ]; then
        echo -e "$(tput setaf 1)Failed to apply webhook validation testing CR$(tput sgr 0)"
        return ${ret}
    fi

    kubectl get alamedanotificationchannels ${crname} -o 'jsonpath={.metadata.annotations.notifying\.containers\.ai\/webhook-validation}' 2>/dev/null | grep -q 'ok'
    if [ "$?" -eq "0" ]; then
        echo "Detection result: webhook validation is enabled"
        return 0
    else
        echo "Detection result: webhook validation is disabled"
        return 14
    fi
}

# Main

kubectl version -o yaml | grep -q "^serverVersion:"
if [ "$?" != "0" ];then
    echo -e "\nPlease login to Kubernetes first."
    exit
fi

test_cr_name="webhook-testing"
test_yaml_file="/tmp/nc_webhook_checking.yaml"

# clean up before testing
kubectl delete alamedanotificationchannel ${test_cr_name} > /dev/null 2>&1

# mutation test
webhook_mutation_checker ${test_cr_name} ${test_yaml_file}
ret_mutation=$?

# validation test
webhook_validation_checker ${test_cr_name} ${test_yaml_file}
ret_validation=$?

# clean up
kubectl delete alamedanotificationchannel ${test_cr_name} > /dev/null 2>&1
rm -f ${test_yaml_file} > /dev/null 2>&1

# display hint if needed
if [ "${ret_mutation}" -ne "0" ] || [ "${ret_validation}" -ne "0" ]; then
    webhook_reminder
    echo -e "\nPlease set up the webhook before executing this script."
    exit
fi

current_channel_encryption="`kubectl get alamedanotificationchannels $default_alamedanotificationchannels -o 'jsonpath={.spec.email.encryption}' 2>/dev/null`"
current_channel_from="`kubectl get alamedanotificationchannels $default_alamedanotificationchannels -o 'jsonpath={.spec.email.from}' 2>/dev/null`"
current_channel_password="*********"
current_channel_port="`kubectl get alamedanotificationchannels $default_alamedanotificationchannels -o 'jsonpath={.spec.email.port}' 2>/dev/null`"
current_channel_server="`kubectl get alamedanotificationchannels $default_alamedanotificationchannels -o 'jsonpath={.spec.email.server}' 2>/dev/null`"
username_cipher="`kubectl get alamedanotificationchannels $default_alamedanotificationchannels -o 'jsonpath={.spec.email.username}' 2>/dev/null`"
current_channel_username="`echo $username_cipher |base64 --decode`"
current_channel_to="`kubectl get alamedanotificationtopics $default_alamedanotificationtopics -o 'jsonpath={.spec.channel.emails[0].to[*]}' 2>/dev/null`"
current_channel_cc="`kubectl get alamedanotificationtopics $default_alamedanotificationtopics -o 'jsonpath={.spec.channel.emails[0].cc[*]}' 2>/dev/null`"

echo -e "\n=================================================================="
echo "Current values from $(tput setaf 6)$default_alamedanotificationchannels$(tput sgr 0) alamedanotificationchannels and $(tput setaf 6)$default_alamedanotificationtopics$(tput sgr 0) alamedanotificationtopics:"
printf '%-19s %-1s %-40s\n' "SMTP server" "=" "$(tput setaf 3)$current_channel_server$(tput sgr 0)"
printf '%-19s %-1s %-40s\n' "SMTP port" "=" "$(tput setaf 3)$current_channel_port$(tput sgr 0)"
printf '%-19s %-1s %-40s\n' "Encryption protocol" "=" "$(tput setaf 3)$current_channel_encryption$(tput sgr 0)"
printf '%-19s %-1s %-40s\n' "Login username" "=" "$(tput setaf 3)$current_channel_username$(tput sgr 0)"
printf '%-19s %-1s %-40s\n' "Login password" "=" "$(tput setaf 3)$current_channel_password$(tput sgr 0)"
printf '%-19s %-1s %-40s\n' "From" "=" "$(tput setaf 3)$current_channel_from$(tput sgr 0)"
printf '%-19s %-1s %-40s\n' "To" "=" "$(tput setaf 3)$current_channel_to$(tput sgr 0)"
printf '%-19s %-1s %-40s\n' "Cc" "=" "$(tput setaf 3)$current_channel_cc$(tput sgr 0)"
echo -e "\n=================================================================="

while [[ "$info_correct" != "y" ]] && [[ "$info_correct" != "Y" ]]
do
    # init variables
    channel_server=""
    channel_port=""
    channel_encryption=""
    channel_username=""
    channel_password=""
    channel_from=""
    channel_to=""
    channel_cc=""

    read -r -p "$(tput setaf 2)Please enter SMTP server:$(tput sgr 0) " channel_server </dev/tty
    read -r -p "$(tput setaf 2)Please enter SMTP port:$(tput sgr 0) " channel_port </dev/tty
    read -r -p "$(tput setaf 2)Please enter Encryption protocol (e.g., ssl,tls,starttls):$(tput sgr 0) " channel_encryption </dev/tty
    read -r -p "$(tput setaf 2)Please enter Login username:$(tput sgr 0) " channel_username </dev/tty
    read -rs -p "$(tput setaf 2)Please enter Login password:$(tput sgr 0) " channel_password </dev/tty
    echo ""
    read -r -p "$(tput setaf 2)Please enter From:$(tput sgr 0) " channel_from </dev/tty
    read -r -p "$(tput setaf 2)Please enter To(seperated by comma):$(tput sgr 0) " channel_to </dev/tty
    read -r -p "$(tput setaf 2)Please enter Cc(seperated by comma):$(tput sgr 0) " channel_cc </dev/tty

    echo -e "\n------------------------------------------------------------------"
    echo "Input Values:"
    printf '%-19s %-1s %-40s\n' "SMTP server" "=" "$(tput setaf 3)$channel_server$(tput sgr 0)"
    printf '%-19s %-1s %-40s\n' "SMTP port" "=" "$(tput setaf 3)$channel_port$(tput sgr 0)"
    printf '%-19s %-1s %-40s\n' "Encryption protocol" "=" "$(tput setaf 3)$channel_encryption$(tput sgr 0)"
    printf '%-19s %-1s %-40s\n' "Login username" "=" "$(tput setaf 3)$channel_username$(tput sgr 0)"
    printf '%-19s %-1s %-40s\n' "Login password" "=" "$(tput setaf 3)$channel_password$(tput sgr 0)"
    printf '%-19s %-1s %-40s\n' "From" "=" "$(tput setaf 3)$channel_from$(tput sgr 0)"
    printf '%-19s %-1s %-40s\n' "To" "=" "$(tput setaf 3)$channel_to$(tput sgr 0)"
    printf '%-19s %-1s %-40s\n' "Cc" "=" "$(tput setaf 3)$channel_cc$(tput sgr 0)"
    echo "------------------------------------------------------------------"

    default="y"
    read -r -p "$(tput setaf 2)Is the above information correct? [default: y]: $(tput sgr 0)" info_correct </dev/tty
    info_correct=${info_correct:-$default}
done

cat > patch.channel.yaml << __EOF__
  spec:
    email:
      encryption:
      from:
      password:
      port:
      server:
      username:
__EOF__

sed -i "/encryption:/ s/$/ $channel_encryption/" patch.channel.yaml
sed -i "/from:/ s/$/ $channel_from/" patch.channel.yaml
sed -i "/password:/ s/$/ $channel_password/" patch.channel.yaml
sed -i "/port:/ s/$/ $channel_port/" patch.channel.yaml
sed -i "/server:/ s/$/ $channel_server/" patch.channel.yaml
sed -i "/username:/ s/$/ $channel_username/" patch.channel.yaml

cat > patch.topics.yaml << __EOF__
spec:
  channel:
    emails:
    - cc:
      name:
      to:
__EOF__

channel_to="[""`echo $channel_to |tr -d '[:space:]'`""]"
channel_cc="[""`echo $channel_cc |tr -d '[:space:]'`""]"

sed -i "/cc:/ s/$/ $channel_cc/" patch.topics.yaml
sed -i "/name:/ s/$/ $default_alamedanotificationchannels/" patch.topics.yaml
sed -i "/to:/ s/$/ $channel_to/" patch.topics.yaml

echo -e "\n$(tput setaf 2)Starting to update alamedanotificationchannels$(tput sgr 0) $(tput setaf 6)$default_alamedanotificationchannels$(tput sgr 0) ..."
kubectl patch alamedanotificationchannels $default_alamedanotificationchannels --type merge --patch "$(cat patch.channel.yaml)"
if [ "$?" != "0" ];then
    echo -e "$(tput setaf 1)Updating channel failed. Please double-check the info you input.$(tput sgr 0)"
    exit
else
    echo -e "Done."
fi

echo -e "\n$(tput setaf 2)Starting to update alamedanotificationtopics$(tput sgr 0) $(tput setaf 6)$default_alamedanotificationtopics$(tput sgr 0) ..."
kubectl patch alamedanotificationtopics $default_alamedanotificationtopics --type merge --patch "$(cat patch.topics.yaml)"
if [ "$?" != "0" ];then
    echo -e "$(tput setaf 1)Updating topic failed. Please double-check the info you input.$(tput sgr 0)"
    exit
else
    echo -e "Done."
fi

read -r -p "$(tput setaf 2)Please enter an email address for receiving test email:$(tput sgr 0) " test_email </dev/tty

cat > patch.channel.testemail.yaml << __EOF__
metadata:
  annotations:
    notifying.containers.ai/test-channel: start
    notifying.containers.ai/test-channel-to: $test_email
__EOF__

echo -e "\n$(tput setaf 2)Starting to send out a test email$(tput sgr 0) ..."
kubectl patch alamedanotificationchannels $default_alamedanotificationchannels --type merge --patch "$(cat patch.channel.testemail.yaml)"
if [ "$?" != "0" ];then
    echo -e "$(tput setaf 1)Test email update failed. Please double-check the info you input.$(tput sgr 0)"
    exit
fi

sleep 10

result_msg="`kubectl get alamedanotificationchannels $default_alamedanotificationchannels -o 'jsonpath={.status.channelTest.message}' 2>/dev/null`"
result_status="`kubectl get alamedanotificationchannels $default_alamedanotificationchannels -o 'jsonpath={.status.channelTest.success}' 2>/dev/null`"

if [ "$result_status" == "true" ];then
    echo -e "\n$(tput setaf 6)Done. The test email sends out successfully. You can now check your email inbox.$(tput sgr 0)"
else
    echo "==================$(tput setaf 1) Error Msg $(tput sgr 0)====================================="
    echo "$result_msg"
    echo "=================================================================="

    echo -e "\n$(tput setaf 1)Test email send out failed. Please double-check the settings you input.$(tput sgr 0)"
fi
