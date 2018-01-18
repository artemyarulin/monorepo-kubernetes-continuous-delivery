set -euo pipefail

# Setup gcloud, service account auth, project, default zone
gc_set_project() {
    local key=$1
    local project=$2
    local zone=$3
    echo $key | base64 --decode --ignore-garbage > ~/.gc_key
    gcloud auth activate-service-account --key-file ~/.gc_key
    gcloud config set project $project
    gcloud config set compute/zone $zone
}

# Authenticate so that kubectl has access to cluster
gc_cluster_auth() {
    local name=$1
    gcloud container clusters get-credentials $name
}

# Creates new kubernetes cluster
gc_create_cluster() {
    set -euo pipefail
    local name=$1
    gcloud container clusters create $name \
           --cluster-version 1.8.5-gke.0 \
           --disk-size 100 \
           --machine-type g1-small \
           --num-nodes 3
}
export -f gc_create_cluster

# Creates (if not yet exists) new namespace and selects that as default one
namespace_switch() {
    set -euo pipefail
    local name=$1 res=0
    kubectl get ns $name || res=$? && true
    if [[ $res -ne 0 ]]; then
        kubectl create ns $name
    fi
    kubectl config set-context $(kubectl config current-context) --namespace=$name
}
export -f namespace_switch

# Build all Dockerfiles (and *.integration) using local docker, builds all 1 by 1
build_local() {
    set -euo pipefail
    local version="$1"
    local filter="$2"
    for dockerfile in $(find . -name "Dockerfile" -o -name "*.integration"); do
        if [[ $filter && $dockerfile != *$filter* ]]; then continue; fi
        dir=$(dirname $dockerfile)
        app=$(echo $dockerfile | cut -d "/" -f 3 | sed "s/^[0-9]*-//")
        tag_suffix=$(basename $dockerfile | sed "s/Dockerfile//; s/\.integration//; s/^/-/; s/^-$//")
        echo "Building $dockerfile"
        (cd $dir && docker build --file $(basename $dockerfile) --tag $app$tag_suffix:$version .)
    done
}
export -f build_local

# Build all Dockerfiles (and *.integration) in parallel using Google Container Builder
# Tries to find previously built image and uses that as cache
build_gc() {
    set -euo pipefail
    local version=$1 namespace=$2 project=$3
    for dockerfile in $(find . -name "Dockerfile" -o -name "*.integration"); do
        dir=$(dirname $dockerfile)
        app=$(echo $dockerfile | cut -d "/" -f 3 | sed "s/^[0-9]*-//")
        tag_suffix=$(basename $dockerfile | sed "s/Dockerfile//; s/\.integration//; s/^/-/; s/^-$//")
        image_name="$namespace/$project/$app$tag_suffix"
        last_app_build=$(gcloud container builds list --filter "images ~ $image_name: AND status = SUCCESS" --format='value(images)' --limit 1)
        if [[ $last_app_build ]]; then
            echo "Found prev build, using cached version $last_app_build for $image_name"
            template_file="container-build-cached.yaml";
        else
            echo "No cached version found, build from scratch"
            template_file="container-build.yaml"
        fi
        cat .circleci/$template_file \
            | sed "s|{CACHED}|$last_app_build|" \
            | sed "s|{NAME}|$image_name:$version|" \
            | sed "s|{DOCKERFILE}|$(basename $dockerfile)|" > ./$dir/build.yaml.tmp
        (cd $dir && gcloud container builds submit --config build.yaml.tmp --async .)
    done

    echo "[$(date)] Waiting for build to complete"
    while true; do
        if [[ $(gcloud container builds list --ongoing --filter "images ~ $namespace/$project/.*:$version" --format json) = "[]" ]]; then
            echo -e "\n[$(date)] Done"
            break
        else
            echo -n "."
            sleep 5
        fi
    done

    failed=$(gcloud container builds list --filter "images ~ $namespace/$project/.*:$version AND status != SUCCESS" --format='value(id)')
    if [[ $failed ]]; then
        echo $failed | xargs -n 1 gcloud container builds log
        gcloud container builds list --filter "images ~ $namespace/$project/.*:$version"
        exit 1
    else
        gcloud container builds list --filter "images ~ $namespace/$project/.*:$version"
    fi
}
export -f build_gc

# Deploy services using locally built images. imagePullPolicy: Never is required so that
# Docker for Mac k8s would use local docker image cache
deploy_services_local() {
    for path in services/*; do
        if [[ $FILTER && $path != *$FILTER* ]]; then continue; fi
        service=$(basename $path | sed "s/^[0-9]-//")
        if [ ! -f $path/config.yaml ]; then continue; fi
        cat $path/config.yaml \
            | sed "s/{IMAGE}/$service:$VERSION"$'\\\n        imagePullPolicy: Never/' \
            | sed "s/{NAME}/$service/" \
            | kubectl apply --filename -
        kubectl rollout status statefulset/$service
    done
}

# Deploy services using Google Container Build images
deploy_services_gc() {
    for path in services/*; do
        service=$(basename $path | sed "s/^[0-9]-//")
        if [ ! -f $path/config.yaml ]; then continue; fi
        cat $path/config.yaml \
            | sed "s/{IMAGE}/$NAMESPACE\/$PROJECT\/$service:$VERSION/" \
            | sed "s/{NAME}/$service/" \
            | kubectl apply --filename -
        kubectl rollout status statefulset/$service
    done
}

# Deploy apps using locally built images. imagePullPolicy: Never is required so that
# Docker for Mac k8s would use local docker image cache
deploy_apps_local() {
    local port=8080
    for path in apps/*; do
        if [[ $FILTER && $path != *$FILTER* ]]; then continue; fi
        app=$(basename $path)
        if [ -f $path/config.yaml ]; then
            cat $path/config.yaml | sed "s/{NAME}/$app/" | kubectl apply --filename -
        fi
        if [ -f $path/app.yaml ]; then
            cat $path/app.yaml \
                | sed "s/{IMAGE}/$app:$VERSION"$'\\\n        imagePullPolicy: Never/' \
                | sed "s/{PORT}/$port/" \
                | sed "s/{NAME}/$app/" \
                | kubectl apply --filename -
            kubectl rollout status deployment/$app
        fi
    done
}

# Deploy apps using Google Container Build images
deploy_apps_gc() {
    local port=8080
    for path in apps/*; do
        app=$(basename $path)
        if [ -f $path/config.yaml ]; then
            cat $path/config.yaml | sed "s/{NAME}/$app/" | kubectl apply --filename -
        fi
        if [ -f $path/app.yaml ]; then
            cat $path/app.yaml \
                | sed "s/{IMAGE}/$NAMESPACE\/$PROJECT\/$app:$VERSION/" \
                | sed "s/{PORT}/$port/" \
                | sed "s/{NAME}/$app/" \
                | kubectl apply --filename -
            kubectl rollout status deployment/$app
        fi
    done
}

# We don't deploy jobs as it starts automatically after deployment and it's not always intended
# But there are may be job config files that later on can be used for job tests
deploy_jobs() {
    for path in jobs/*; do
        if [[ $FILTER && $path != *$FILTER* ]]; then continue; fi
        app=$(basename $path)
        if [ -f $path/config.yaml ]; then
            cat $path/config.yaml | sed "s/{NAME}/$app/" | kubectl apply --filename -
        fi
    done
}

# Runs all *.integration in parallel as k8s jobs. We also attach [app|service|job] config if exits so that
# important environment variables can be accessed in test as well. Test runs in 3 stages:
# 1 Init container will prepeare files for integraion (think docker --volume $PWD:/srv)
# 2 Integration runs in k8s context with access to apps and services. /srv is writable and has files from integration folder
# 3 Sidecar container waits until main job has finished and copy /srv to sharer to be fetched later on for pushback logic
run_integrations() {
    image_source=$1
    tasks=()
    for integration in $(find . -name "*.integration"); do
        if [[ $FILTER && $integration != *$FILTER* ]]; then continue; fi
        key=ci-$VERSION-$(echo $integration | md5 | sed "s/  -//")
        app=$(echo $integration | cut -d "/" -f 3 | sed "s/^[0-9]*-//")
        tag_suffix=$(basename $integration | sed "s/\.integration//; s/^/-/")
        image_name="$app$tag_suffix:$VERSION"
        if [[ $image_source == "gce" ]]; then image_name="$NAMESPACE\/$PROJECT\/"$image_name; fi
        name=$app$tag_suffix"-"${#tasks[@]}
        tasks+=($name)
        target_config=$(echo $integration | cut -d "/" -f 1-3)/config.yaml
        config=""
        if [ -f "$target_config" ]; then
            config=$'- configMapRef:\\\n              name: '$app
        fi
        service_acc=""
        if [[ $image_source == "gce" ]]; then
            service_acc="serviceAccountName: integration-runner"
        fi
        cat $(dirname $0)/integration-template.yaml \
            | sed "s/{NAME}/$name/" \
            | sed "s/{CONFIG}/$config/" \
            | sed "s|{IMAGE}|$image_name|" \
            | sed "s/{SERVICE_ACC}/$service_acc/" \
            | sed "s/{FOLDER}/$key/" \
            | kubectl apply --force --filename - # force is needed as we may need to replace existing job
    done
    if [ ${#tasks[@]} -ne 0 ]; then
        cmd_wait="bash $(dirname $0)/wait-for-task.sh --task-name"
        printf '%s\n' "${tasks[@]}" | parallel --halt 2 $cmd_wait
    fi
}

# SSH file exchange - used for pulling integration related files and pushing back after integraion changes
create_sharer() {
    set -euo pipefail
    kubectl apply --filename $(dirname $0)/sharer.yaml
    kubectl rollout status deployment/sharer
    sharer=$(kubectl get pods --selector="app=sharer" --output=jsonpath={.items..metadata.name})
    for dockerfile in $(find . -name "*.integration"); do
        if [[ $FILTER && $dockerfile != *$FILTER* ]]; then continue; fi
        name=ci-$VERSION-$(echo $dockerfile | md5 | sed "s/  -//")
        target_dir=$(dirname $dockerfile)
        echo "Prepearing data for $target_dir"
        kubectl exec $sharer -- mkdir /srv/$name
        (cd $target_dir && kubectl cp . $sharer:/srv/$name/)
    done
}
export -f create_sharer

# Fetch data after integration and make a commit back when non local env is used
fetch_integration_data() {
    local version=$1 pushback=$2
    sharer=$(kubectl get pods --selector="app=sharer" --output=jsonpath={.items..metadata.name})
    msgs=()
    for integration in $(find . -name "*.integration"); do
        if [[ $FILTER && $integration != *$FILTER* ]]; then continue; fi
        name=ci-$version-$(echo $integration | md5 | sed "s/  -//")
        target_dir=$(dirname $integration)
        tag_suffix=$(basename $integration | sed "s/\.integration//; s/^/-/")
        friendly_name="$app$tag_suffix"
        (cd $target_dir && kubectl cp $sharer:/srv/$name .)
        if [[ $pushback == true && $(git status --porcelain $target_dir) ]]; then
            git stash save --include-untracked
            msgs+=("AUTOBOT: $friendly_name")
        fi
    done
    if [[ $pushback == true ]]; then
        for (( idx=${#msgs[@]}-1 ; idx>=0 ; idx-- )) ; do
            git stash pop
            git add --all
            git commit -m "${msgs[idx]}"
        done
        if [[ $(git log origin/$CIRCLE_BRANCH..$CIRCLE_BRANCH) ]]; then
            git push --set-upstream pushback $CIRCLE_BRANCH || true
        fi
    fi
}

# Checkc that no pods were restrted. Ensures that pods are stable
ensure_none_restarted() {
    # 1.9 has much better feature for filter https://github.com/kubernetes/kubernetes/issues/49387
    restarted=$(kubectl get pods --output="jsonpath={range .items[*]}{.metadata.name},{.status.containerStatuses..restartCount}{\"\n\"}{end}" | sed "/,0$/d" | cut -d ',' -f 1)
    if [[ $restarted ]]; then
        echo "$restarted" | xargs -n 1 kubectl logs --previous
        echo "Pods were restarted during testing: $restarted"
        exit 1
    fi
}

# Runs integration locally
test_local() {
    # due to the bug https://github.com/kubernetes/kubernetes/issues/54723 we have to wait until all terminating pods got cleaned up
    # otherwise there is a good chance that request ends up on dead pod which will break tests
    # fixed in k8s 1.8.3, remove once Docker For Mac starts using new k8s version
    while [[ $(kubectl get pods | grep "Terminating") ]]; do
        echo "Waiting for terminating pods..."
        sleep 3
    done
    run_integrations "local"
    fetch_integration_data "$VERSION" false
    kubectl get jobs --show-all
}

# Runs integration in GC
test_gc() {
    ensure_none_restarted
    run_integrations "gce"
    fetch_integration_data "$VERSION" true
    kubectl get jobs --show-all
    ensure_none_restarted
}

# Sets current build number
set_version() {
    if [[ -n "${CIRCLE_BUILD_NUM:-}" ]]; then
        VERSION=$CIRCLE_BUILD_NUM
    else
        VERSION=$(date +%s)
    fi
    echo "Version $VERSION"
}

# Initialize cluster wide secrets
init_secrets() {
    if [[ -f env/secrets.yaml ]]; then
        kubectl apply --filename env/secrets.yaml
    fi
}

# Runs env -> build -> deploy -> test workflow
run() {
    local auth=$1 env=$2 build=$3 test=$4 services=$5 apps=$6
    eval "$auth"
    (echo "$env"; echo "$build") | parallel
    init_secrets
    if [[ $ACTION == "test" ]]; then create_sharer; fi
    eval "$services"
    eval "$apps"
    deploy_jobs
    if [[ $ACTION == "test" ]]; then eval "$test"; fi
}

auth_local() {
    kubectl config use-context docker-for-desktop
}

auth_gc() {
    gc_set_project $GC_SERVICE_KEY $PROJECT $COMPUTE_ZONE
    gc_cluster_auth $PROD_CLUSTER
}

env_local() {
    set -euo pipefail
    local project=$1 version=$2
    namespace_switch $project
}
export -f env_local

# Integration tests has to have an access to k8s API from inside the pod
# New service account is created for that here
set_integration_permission() {
    set -euo pipefail
    local ns_name=$1
    cur_service_acc=$(gcloud config get-value account)
    raised_perm_name="ci-service-acc-admin"
    # Before creating new service account we need to raise cur acc permission
    if [[ $(kubectl get clusterrolebinding | grep $raised_perm_name) ]]; then
        echo "Role already exists $raised_perm_name"
    else
        kubectl create clusterrolebinding $raised_perm_name \
                --clusterrole=cluster-admin \
                --user=$cur_service_acc
    fi
    name="integration-runner"
    cat .circleci/permission.yaml | \
        sed "s/{NAME}/$name/" | \
        sed "s/{NAMESPACE}/$ns_name/" | \
        kubectl apply --filename -
}
export -f set_integration_permission

env_gc() {
    set -euo pipefail
    local project=$1 version=$2 isolation=$3
    name="ci-$project-$version"
    ns=$name
    if [[ $isolation == "cluster" ]]; then
        gc_create_cluster $name
        ns="default"
    else
        namespace_switch $name
    fi
    if [[ $ACTION == "test" ]]; then set_integration_permission $ns; fi
}
export -f env_gc

set_version

if [[ $ENV == "local" ]]; then
    auth="auth_local"
    env="env_local $PROJECT $VERSION $ACTION"
    build="build_local $VERSION \"$FILTER\""
    test="test_local"
    services="deploy_services_local"
    apps="deploy_apps_local"
    run "$auth" "$env" "$build" "$test" "$services" "$apps"
elif [[ $ENV == "test" ]]; then
    auth="auth_gc"
    env="env_gc $PROJECT $VERSION $ISOLATION"
    build="build_gc $VERSION $NAMESPACE $PROJECT"
    test="test_gc"
    services="deploy_services_gc"
    apps="deploy_apps_gc"
    run "$auth" "$env" "$build" "$test" "$services" "$apps"
elif [[ $ENV == "prod" && $ACTION == "build" ]]; then
    auth="auth_gc"
    env="echo Using production environment"
    build="build_gc $VERSION $NAMESPACE $PROJECT"
    test="echo No testing on prod"
    services="deploy_services_gc"
    apps="deploy_apps_gc"
    run "$auth" "$env" "$build" "$test" "$services" "$apps"
else
    echo "Not supported env or project: $ENV, $PROJECT"
    exit 1
fi
