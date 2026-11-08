# RecallReach on InterSystems IRIS for Health Community + AI Hub (build 2027.1.0AI.109.0, arm64/amd64).
# The image comes from the InterSystems early-access portal and is not on a public registry:
# load it first (see README), then `docker compose up -d --build`.
ARG IRIS_IMAGE=intersystems/irishealth-community:2027.1.0AI.109.0
FROM ${IRIS_IMAGE}

USER root
RUN mkdir -p /opt/recallreach/recordings && chown -R irisowner:irisowner /opt/recallreach
USER irisowner

COPY --chown=irisowner:irisowner python/recallreach_core /usr/irissys/mgr/python/recallreach_core
COPY --chown=irisowner:irisowner python/tests /opt/recallreach/python/tests
COPY --chown=irisowner:irisowner data /opt/recallreach/data
COPY --chown=irisowner:irisowner data/recordings /opt/recallreach/recordings
COPY --chown=irisowner:irisowner web /opt/recallreach/web
COPY --chown=irisowner:irisowner src /opt/recallreach/src
COPY --chown=irisowner:irisowner iris.script /tmp/iris.script

# compile, load data, run the six history recalls through the real production (replay mode), then stop
RUN iris start IRIS \
 && iris session IRIS < /tmp/iris.script \
 && iris stop IRIS quietly
