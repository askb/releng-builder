#!/bin/bash
virtualenv $WORKSPACE/.venv-openstack
source $WORKSPACE/.venv-openstack/bin/activate
pip install --upgrade pip
pip install --upgrade python-openstackclient python-heatclient
pip freeze

cd /builder/openstack-hot

JOB_SUM=`echo $JOB_NAME | sum | awk '{{ print $1 }}'`
VM_NAME="$JOB_SUM-$BUILD_NUMBER"

OS_TIMEOUT=10  # Minutes to wait for OpenStack VM to come online
STACK_RETRIES=3  # Number of times to retry creating a stack before fully giving up
STACK_SUCCESSFUL=false
# seq X refers to waiting for X minutes for OpenStack to return
# a status that is not CREATE_IN_PROGRESS before giving up.
openstack --os-cloud rackspace limits show --absolute
openstack --os-cloud rackspace limits show --rate
echo "Trying up to $STACK_RETRIES times to create $STACK_NAME."
for try in `seq $STACK_RETRIES`; do
    openstack --os-cloud rackspace stack create --timeout $OS_TIMEOUT -t csit-2-instance-type.yaml -e $WORKSPACE/opendaylight-infra-environment.yaml --parameter "job_name=$VM_NAME" --parameter "silo=$SILO" $STACK_NAME
    openstack --os-cloud rackspace stack list
    echo "Waiting for $OS_TIMEOUT minutes to create $STACK_NAME."
    for i in `seq $OS_TIMEOUT`; do
        sleep 60
        OS_STATUS=`openstack --os-cloud rackspace stack show -f json -c stack_status $STACK_NAME | jq -r '.stack_status'`

        case "$OS_STATUS" in
            CREATE_COMPLETE)
                echo "Stack initialized on infrastructure successful."
                STACK_SUCCESSFUL=true
                break
            ;;
            CREATE_FAILED)
                echo "ERROR: Failed to initialize infrastructure. Deleting stack and possibly retrying to create..."
                openstack --os-cloud rackspace stack list
                openstack --os-cloud rackspace stack delete --yes $STACK_NAME
                openstack --os-cloud rackspace stack show $STACK_NAME
                # after stack delete, poll for 10m to know when stack is fully removed
                # the logic here is that when "stack show $STACK_NAME" does not contain $STACK_NAME
                # we assume it's successfully deleted and we can break to retry
                for i in `seq 20`; do
                    sleep 30;
                    STACK_SHOW=$(openstack --os-cloud rackspace stack show $STACK_NAME)
                    echo $STACK_SHOW
                    if [[ $STACK_SHOW == *"DELETE_FAILED"* ]]; then
                        echo "stack delete failed. trying to stack abandon now"
                        openstack --os-cloud rackspace stack abandon $STACK_NAME
                        STACK_SHOW=$(openstack --os-cloud rackspace stack show $STACK_NAME)
                        echo $STACK_SHOW
                    fi
                    if [[ $STACK_SHOW != *"$STACK_NAME"* ]]; then
                        echo "stack show on $STACK_NAME came back empty. Assuming successful delete"
                        break
                    fi
                done
                # if we still see $STACK_NAME in $STACK_SHOW it means the delete hasn't fully
                # worked and we can exit forcefully
                if [[ $STACK_SHOW == *"$STACK_NAME"* ]]; then
                    echo "stack $STACK_NAME still in stack show output after polling. Quitting!"
                    exit 1
                fi
                break
            ;;
            CREATE_IN_PROGRESS)
                echo "Waiting to initialize infrastructure."
                continue
            ;;
            *)
                echo "Unexpected status: $OS_STATUS"
                exit 1
            ;;
        esac
    done
    if $STACK_SUCCESSFUL; then
        break
    fi
done

# capture stack info in console logs
openstack --os-cloud rackspace stack show $STACK_NAME

if ! $STACK_SUCCESSFUL; then
    exit 1
fi
