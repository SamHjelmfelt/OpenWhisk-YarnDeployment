# OpenWhisk-YarnDeployment
This project deploys OpenWhisk locally and on YARN.

This project comes preconfigured with NiFi-Fn support using the "samhjelmfelt/nifi-fn:latest" image.
https://issues.apache.org/jira/browse/NIFI-5922

The "docker-whisk-controller.env" file can be used to configure the OpenWhisk services. Commenting out the the YARN configurations (the first eight in the file) will result in action containers running locally instead of on YARN.

For a quickstart, the following script will
1. Download this repo
2. Run minio, couchdb, kafka, and zookeeper containers locally
3. Run redis, controller, invoker, and action containers on YARN (localhost:8088)
4. Configure and run the api-gateway container locally

Docker is required.

```
# Dependencies for minimal hosts
#yum install git wget unzip netcat

# (Optional) Download and run YARN sandbox (YARN RM URL will be localhost:8088). Image is ~5GB
curl -L https://github.com/SamHjelmfelt/Ember/archive/v1.1.zip -o Ember_1.1.zip
unzip Ember_1.1.zip
cd Ember-1.1/
./ember.sh createFromPrebuiltSample samples/yarnquickstart/yarnquickstart-sample-hotfix.ini

# Download this repo
curl -L https://github.com/SamHjelmfelt/OpenWhisk-YarnDeployment/archive/master.zip -o OpenWhisk-YarnDeployment-master.zip
unzip OpenWhisk-YarnDeployment-master.zip
cd OpenWhisk-YarnDeployment-master

# Run OpenWhisk on YARN
./YARNdeployment.sh quick-start-yarn ember localhost:8088

# Test
./openwhisk-src/bin/wsk -i action create hello hello.js
./openwhisk-src/bin/wsk -i action invoke --blocking --result hello --param name "World"
```

Usage:
```
Setup:
YARNdeployment.sh download-source - Git clones the OpenWhisk main branch into ./openwhisk-src
YARNdeployment.sh build-docker    - Compiles the OpenWhisk source and builds the OpenWhisk images with a prefix of 'openwhisk'
YARNdeployment.sh pull-images     - Pulls the latest OpenWhisk images
YARNdeployment.sh download-cli    - Downloads the OpenWhisk cli into ./openwhisk-src/bin

Container Types:
  Container groups:     stateful, stateless, all
  Stateful containers:  minio, couchdb, zookeeper, kafka
  Stateless containers: redis, controller, invoker, apigateway

Local Machine Operations:
YARNdeployment.sh run-local     <Container | Container Group> <docker network> [withJaaS] -runs the container or container group
YARNdeployment.sh rerun-local   <Container | Container Group> <docker network> [withJaaS] -removes and runs the container or container group
YARNdeployment.sh start-local   <Container | Container Group>                             -starts the container or container group
YARNdeployment.sh stop-local    <Container | Container Group>                             -stops the container or container group
YARNdeployment.sh restart-local <Container | Container Group>                             -stops and starts the container or container group
YARNdeployment.sh remove-local  <Container | Container Group>                             -removes the container or container group

YARN Operations (stateless only):
YARNdeployment.sh run-yarn    stateless <docker network> <RM URL> <minio host> <couchdb host> <zookeeper host> <kafka host>
YARNdeployment.sh rerun-yarn  stateless <docker network> <RM URL> <minio host> <couchdb host> <zookeeper host> <kafka host>
YARNdeployment.sh remove-yarn stateless <RM URL>

Shortcuts:
YARNdeployment.sh quick-start-local <docker network> - Executes download-source, pull-images, download-cli, run-local all
YARNdeployment.sh quick-start-yarn  <docker network> <RM URL> - Executes download-source, pull-images, download-cli, run-local stateful, run-yarn stateless
```
