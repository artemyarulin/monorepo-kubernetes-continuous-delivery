set -o errexit
set -o nounset
set -o pipefail

name=ci-$PROJECT-$VERSION
kubectl get pods --show-all

if [[ $ISOLATION == "cluster" ]]; then
    disks_output=$(kubectl get persistentvolumes --output yaml)
    gcloud container clusters delete $name --quiet
    attached_disks=$(echo "$disks_output" | grep "pdName:" | sed "s/pdName: //")
    echo $attached_disks | xargs gcloud compute disks delete
else
    kubectl delete ns $name
    date_range=$(date +%Y-%m-%d --date="1 day ago")
    echo "Range: $date_range"
    filter="name ~ '^ci-*' AND creationTimestamp.date('%Y-%m-%d', Z)<'$date_range'"
    disks=$(gcloud compute disks list --format "value(name)" --filter "$filter")
    echo "Disks: $disks"
    if [[ $disks ]]; then
        echo "$disks" | xargs -n 1 -P 10 gcloud compute disks delete --quiet
    fi
fi
