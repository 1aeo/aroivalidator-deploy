# AROI Validator cron jobs - managed via /etc/cron.d/
# Update: sudo cp ~/aroivalidator-deploy/configs/aroivalidator.cron.d /etc/cron.d/aroivalidator
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
MAILTO=""
5 * * * * ${CRON_USER} ${DEPLOY_DIR}/scripts/run-batch-validation.sh >> ${DEPLOY_DIR}/logs/cron.log 2>&1
0 2 1 * * ${CRON_USER} ${DEPLOY_DIR}/scripts/compress-old-data.sh >> ${DEPLOY_DIR}/logs/compression.log 2>&1
