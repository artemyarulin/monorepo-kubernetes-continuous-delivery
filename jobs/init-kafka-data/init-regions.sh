set -euo pipefail

topics=(
    "regions_0" # Country
    "regions_1" # City
    "regions_2" # District
)

regions_0=(
    'finland:{"name":"Finland"}'
)
regions_1=(
    'helsinki:{"region_0":"finland","name":"Helsinki"}'
    'espoo:   {"region_0":"finland","name":"Espoo"}'
    'vantaa:  {"region_0":"finland","name":"Vantaa"}'
)
regions_2=(
    'kivenlahti:{"region_0":"finland","region_1":"Espoo"}'
)

function add_topic() {
    local topic=$1
    kafka-topics --create \
                 --if-not-exists \
                 --zookeeper $ZK \
                 --partitions 1 \
                 --replication-factor 1 \
                 --config cleanup.policy=compact \
                 --topic $topic
}

function add_item() {
    local topic=$1 item=$2
    echo "$item" | kafka-console-producer \
                       --topic "$topic" \
                       --broker-list $KAFKA \
                       --property "parse.key=true" \
                       --property "key.separator=:"
}

for topic in "${topics[@]}"; do add_topic $topic; done
for item in "${regions_0[@]}"; do add_item "regions_0" $item; done
for item in "${regions_1[@]}"; do add_item "regions_1" $item; done
for item in "${regions_2[@]}"; do add_item "regions_2" $item; done
