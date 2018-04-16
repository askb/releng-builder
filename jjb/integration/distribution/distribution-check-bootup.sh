
CONTROLLERMEM="3072m"
ACTUALFEATURES="odl-integration-all"
BUNDLEVERSION="$(xpath distribution/pom.xml '/project/version/text()' 2> /dev/null)"
BUNDLEFOLDER="${KARAF_ARTIFACT}-${BUNDLEVERSION}"
BUNDLE="${BUNDLEFOLDER}.zip"
BUNDLE_PATH="/tmp/r/org/opendaylight/integration/${KARAF_ARTIFACT}/${BUNDLEVERSION}/${BUNDLE}"

echo "Kill any controller running"
ps axf | grep karaf | grep -v grep | awk '{print "kill -9 " $1}' | sh

echo "Clean Existing distribution"
rm -rf ${BUNDLEFOLDER}

echo "Copying the distribution..."
cp "${BUNDLE_PATH}" .

echo "Extracting the new controller..."
unzip -q "${BUNDLE}"

echo "Configuring the startup features..."
FEATURESCONF="${WORKSPACE}/${BUNDLEFOLDER}/etc/org.apache.karaf.features.cfg"
FEATURE_TEST_STRING="features-integration-test"
if [[ "$KARAF_VERSION" == "karaf4" ]]; then
    FEATURE_TEST_STRING="features-test"
fi

sed -ie "s%\(featuresRepositories=\|featuresRepositories =\)%featuresRepositories = mvn:org.opendaylight.integration/${FEATURE_TEST_STRING}/${BUNDLEVERSION}/xml/features,%g" ${FEATURESCONF}

# Add actual boot features.
sed -ie "s/\(featuresBoot=\|featuresBoot =\)/featuresBoot = ${ACTUALFEATURES},/g" "${FEATURESCONF}"
cat "${FEATURESCONF}"

echo "Configuring the log..."
LOGCONF="${WORKSPACE}/${BUNDLEFOLDER}/etc/org.ops4j.pax.logging.cfg"
sed -ie 's/log4j.appender.out.maxFileSize=1MB/log4j.appender.out.maxFileSize=20MB/g' "${LOGCONF}"
cat "${LOGCONF}"

echo "Configure max memory..."
MEMCONF="${WORKSPACE}/${BUNDLEFOLDER}/bin/setenv"
sed -ie "s/2048m/${CONTROLLERMEM}/g" "${MEMCONF}"
cat "${MEMCONF}"

echo "Listing all open ports on controller system"
netstat -pnatu

echo "redirected karaf console output to karaf_console.log"
export KARAF_REDIRECT="${WORKSPACE}/${BUNDLEFOLDER}/data/log/karaf_console.log"
mkdir -p ${WORKSPACE}/${BUNDLEFOLDER}/data/log

if [ "${JDKVERSION}" == 'openjdk8' ]; then
    echo "Setting the JRE Version to 8"
    # dynamic_verify does not allow sudo, JAVA_HOME should be enough for karaf start.
    # sudo /usr/sbin/alternatives --set java /usr/lib/jvm/java-1.8.0-openjdk-1.8.0.60-2.b27.el7_1.x86_64/jre/bin/java
    export JAVA_HOME='/usr/lib/jvm/java-1.8.0'
elif [ "${JDKVERSION}" == 'openjdk7' ]; then
    echo "Setting the JRE Version to 7"
    # dynamic_verify does not allow sudo, JAVA_HOME should be enough for karaf start.
    # sudo /usr/sbin/alternatives --set java /usr/lib/jvm/java-1.7.0-openjdk-1.7.0.85-2.6.1.2.el7_1.x86_64/jre/bin/java
    export JAVA_HOME='/usr/lib/jvm/java-1.7.0'
fi
readlink -e "${JAVA_HOME}/bin/java"
echo "JDK Version should be overriden by JAVA_HOME"
java -version

echo "Redirecting karaf console output to karaf_console.log"
export KARAF_REDIRECT="${WORKSPACE}/${BUNDLEFOLDER}/data/log/karaf_console.log"
mkdir -p ${WORKSPACE}/${BUNDLEFOLDER}/data/log

echo "Starting controller..."
${WORKSPACE}/${BUNDLEFOLDER}/bin/start

# No need for verbose printing during repeating operations.
set +x

function dump_log_and_exit {
    echo "Dumping first 500K bytes of karaf log..."
    head --bytes=500K "${WORKSPACE}/${BUNDLEFOLDER}/data/log/karaf.log"
    echo "Dumping last 500K bytes of karaf log..."
    tail --bytes=500K "${WORKSPACE}/${BUNDLEFOLDER}/data/log/karaf.log"
    cp "${WORKSPACE}/${BUNDLEFOLDER}/data/log/karaf.log" .
    cp "${WORKSPACE}/${BUNDLEFOLDER}/data/log/karaf_console.log" .
    exit 1
}

echo "Waiting up to 5 minutes for controller to come up, checking every 5 seconds..."
if [ "${DISTROSTREAM}" == "carbon" ] || [ "${DISTROSTREAM}" == "nitrogen" ]; then
    # Only oxygen and above have the infrautils.ready feature, so using REST API to determine if the controller is ready.
    COUNT="0"
    while true; do
        COUNT=$(( ${COUNT} + 5 ))
        sleep 5
        echo "already waited ${COUNT} seconds..."
        RESP="$(curl --user admin:admin -sL -w "%{http_code} %{url_effective}\\n" http://localhost:8181/restconf/modules -o /dev/null || true)"
        echo ${RESP}
        if [[ ${RESP} == *"200"* ]]; then
            echo "Controller is UP"
            break
        elif (( "${COUNT}" > "300" )); then
            echo "Timeout Controller DOWN"
            dump_log_and_exit
        fi
    done
else
    COUNT="0"
    while true; do
        COUNT=$(( ${COUNT} + 5 ))
        sleep 5
        echo "already waited ${COUNT} seconds..."
        if grep --quiet 'org.opendaylight.infrautils.ready-impl.*System ready' "${WORKSPACE}/${BUNDLEFOLDER}/data/log/karaf.log"; then
            echo "Controller is UP"
            break
        elif (( "${COUNT}" > "300" )); then
            echo "Timeout Controller DOWN"
            dump_log_and_exit
        fi
    done
fi

set -x

# echo "Checking OSGi bundles..."
# sshpass seems to fail with new karaf version
# sshpass -p karaf ${WORKSPACE}/${BUNDLEFOLDER}/bin/client -u karaf 'bundle:list'

echo "Listing all open ports on controller system"
netstat -pnatu

function exit_on_log_file_message {
    echo "looking for \"$1\" in karaf.log file"
    if grep --quiet "$1" "${WORKSPACE}/${BUNDLEFOLDER}/data/log/karaf.log"; then
        echo ABORTING: found "$1"
        dump_log_and_exit
    fi

    echo "looking for \"$1\" in karaf_console.log file"
    if grep --quiet "$1" "${WORKSPACE}/${BUNDLEFOLDER}/data/log/karaf_console.log"; then
        echo ABORTING: found "$1"
        dump_log_and_exit
    fi
}

exit_on_log_file_message 'BindException: Address already in use'
exit_on_log_file_message 'server is unhealthy'

echo "Fetching Karaf logs"
# TODO: Move instead of copy? Gzip?
cp "${WORKSPACE}/${BUNDLEFOLDER}/data/log/karaf.log" .
cp "${WORKSPACE}/${BUNDLEFOLDER}/data/log/karaf_console.log" .

echo "Kill controller"
ps axf | grep karaf | grep -v grep | awk '{print "kill -9 " $1}' | sh

echo "Bug 4628: Detecting misplaced config files"
pushd "${WORKSPACE}/${BUNDLEFOLDER}" || exit
XMLS_FOUND="$(echo *.xml)"
popd || exit
if [ "$XMLS_FOUND" != "*.xml" ]; then
    echo "Bug 4628 confirmed."
    ## TODO: Uncomment the following when ODL is fixed, to guard against regression.
    # exit 1
else
    echo "Bug 4628 not detected."
fi

# vim: ts=4 sw=4 sts=4 et ft=sh :
