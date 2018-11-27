# OpenWhisk-YarnDeployment

A refactored version of the openwhisk-devtools docker compose project made specifically for OpenWhisk on YARN. The "docker-whisk-controller.env" file can be used to configure the OpenWhisk services.

For a quickstart run the following. It will git clone the openwhisk repo, compile the source, build the docker images, and launch both stateful and stateless master services on the local machine.
```
./YARNdeployment.sh quick-start https://github.com/SamHjelmfelt/incubator-openwhisk.git
```

Usage:
```
./YARNdeployment.sh download-cli - Downloads the OpenWhisk cli into ./openwhisk-src/bin
./YARNdeployment.sh download-source <git url> - Clones the provided git repo into ./openwhisk-src
./YARNdeployment.sh build-docker - Compiles the OpenWhisk source and builds the OpenWhisk images with a prefix of 'openwhisk'

./YARNdeployment.sh start-stateful  - Starts the stateful containers:   ow_minio, ow_couchdb, ow_zookeeper, ow_kafka, ow_redis
./YARNdeployment.sh stop-stateful   - Stops the stateful containers:    ow_minio, ow_couchdb, ow_zookeeper, ow_kafka, ow_redis
./YARNdeployment.sh stop-stateful   - Removes the stateful containers:  ow_minio, ow_couchdb, ow_zookeeper, ow_kafka, ow_redis

./YARNdeployment.sh start-stateless - Starts the stateless containers:  ow_controller, ow_invoker, ow_apigateway
./YARNdeployment.sh stop-stateless  - Stops the stateless containers:   ow_controller, ow_invoker, ow_apigateway
./YARNdeployment.sh stop-stateless  - Removes the stateless containers: ow_controller, ow_invoker, ow_apigateway

./YARNdeployment.sh init-cli - Initializes the cli with the gateway endpoint and guest auth
./YARNdeployment.sh quick-start <git url> - Runs download-source, build-docker, download-cli, start-stateful, start-stateless, init-cli
./YARNdeployment.sh launch - Runs start-stateful, start-stateless, init-cli
```
