# Services

Services are statefulsets, e.g. mysql, redis or anything else that has any kind of state. There are cases when services depends on each other and requires certain order in which they may be deployed. For such situation service folder name may start with number, like in this example zookeeper will be deployed first, kafka only after
