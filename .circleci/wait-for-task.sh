set -o nounset
set -o pipefail

if [ "$#" -ne 2 ]; then echo "Usage: --task-name [task name to wait]"; exit 1; fi
JOB_NAME=$2

echo "[$(date)] Waiting for job to complete"
while true; do
    failed=$(kubectl get jobs --selector="job-name=$JOB_NAME" --output=jsonpath={.items..status.failed})
    succeeded=$(kubectl get jobs --selector="job-name=$JOB_NAME" --output=jsonpath={.items..status.succeeded})
    if [[ $failed ]] || [[ $succeeded ]] ; then
        break
    else
        echo -n "."
        sleep 5
    fi
done

job_pod=$(kubectl get pods --selector="job-name=$JOB_NAME" --show-all --output=jsonpath={.items..metadata.name})
echo "----------------- $JOB_NAME logs ------------------"
kubectl logs $job_pod --container $JOB_NAME

if [[ $(kubectl get jobs --selector="job-name=$JOB_NAME" --output=jsonpath={.items..status.succeeded}) ]]; then
    exit 0
else
    exit 1
fi
