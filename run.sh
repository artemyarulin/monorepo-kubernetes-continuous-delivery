ACTION="$1"
PARAM="$2"

function usage() {
    echo "Usage:"
    echo "./run.sh build [FILTER]  # FILTER is an optional podname"
    echo "./run.sh test [FILTER]   # FILTER is an optional podname"
    echo "./run.sh switch [ENV]    # ENV is 'prod' or empty for local env"
    echo "./run.sh expose [EXPOSE] # EXPOSE is podname OR podname:podport or podname1:podport1 podname2:podport2 ..."
    exit 1
}

if [[ "$ACTION" == "build" ]]; then
    ENV=local PROJECT=example ACTION=build FILTER="$PARAM" bash .circleci/ci.sh
elif [[ "$ACTION" == "test" ]]; then
    ENV=local PROJECT=example ACTION=test FILTER="$PARAM" bash .circleci/ci.sh
elif [[ "$ACTION" == "expose" ]]; then
    if [[ "$#" -eq 2 ]]; then
        kubectl port-forward `kubectl get pods --selector="app=$PARAM" --output="jsonpath={..metadata.name}" | cut -f 1 -d " "` 8080
    elif [[ "$#" -gt 2 ]]; then
        tasks=()
        for i in `seq 2 2 "$#"`; do
            name="${!i}"
            portIdx="$(($i + 1))"
            port="${!portIdx}"
            cmd='kubectl port-forward `kubectl get pods --selector="app='$name'" --output="jsonpath={..metadata.name}" | cut -f 1 -d " "` '$port':8080'
            tasks+=("$cmd")
        done
        parallel --halt 2 --line-buffer ::: "${tasks[@]}"
    else
        usage
    fi
elif [[ "$ACTION" == "switch" ]]; then
    if [[ "$PARAM" == "prod" ]]; then
       gcloud config set project project-example
       gcloud container clusters get-credentials project-example
    else
       kubectl config use-context docker-for-desktop
    fi
else
    usage
fi
