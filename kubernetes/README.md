# Overview
This solution requires OpenEMR Docker 8.1.0 or higher. While not a fully hardened production deployment, this provides a solid working foundation with mTLS encryption, Redis Sentinel failover, and multi-node support, and should open the door to a myriad of other Kubernetes-based solutions.

OpenEMR Kubernetes orchestration. Orchestration included OpenEMR, MariaDB, Redis, and phpMyAdmin.
  - OpenEMR - 3 deployment replications of OpenEMR are created. Replications can be increased/decreased. Ports for both http and https.
  - MariaDB - 2 statefulset replications of MariaDB (1 primary/master with 1 replica/slave) are created. Replications can be increased/decreased which will increase/decrease number of replica/slaves. Connections use mTLS (mutual TLS / X509 client certificate verification) by default, including replication traffic. See the **MariaDB Connection Security** section below for details and how to downgrade to TLS-only or plain TCP.
  - Redis - Configured to support failover. There is 1 master and 2 slaves (no read access on slaves) for a statefulset and 3 sentinels for another statefulset. OpenEMR connects directly to Redis with mTLS (mutual TLS / X509 client certificate verification) by default. The primary/slaves and sentinels would require script changes if wish to increase/decrease replicates for these since these are hard-coded several places in the scripts. There are 3 users/passwords (`default`, `replication`, `admin`) used in this redis scheme. All passwords are stored in the `redis-credentials` Kubernetes Secret (redis/secret.yaml) and should be changed for production use. The `default` is the typical worker/app/client user. See the **Redis Connection Security** section below for details on the default mTLS configuration and how to downgrade to TLS-only or plain TCP.
  - phpMyAdmin - There is 1 deployment instance of phpMyAdmin. Ports for both http and https.

## MariaDB Connection Security
By default, MariaDB connections use **mTLS (mutual TLS)** with X509 client certificate verification for all connections (OpenEMR, phpMyAdmin, and replication). All certificates are managed by cert-manager. To downgrade the connection security:

### Downgrade to TLS (encrypted, no client certs)
1. `mysql/configmap.yaml`: In primary.sql, change `REQUIRE X509` to `REQUIRE SSL`. In secondary.sql, remove the `MASTER_SSL_CERT` and `MASTER_SSL_KEY` lines
2. `openemr/deployment.yaml`: Change `FORCE_DATABASE_X509_CONNECT` to `FORCE_DATABASE_SSL_CONNECT` and remove the `tls.crt` (mysql-cert) and `tls.key` (mysql-key) items from the `mysql-openemr-client-certs` volume
3. `phpmyadmin/configmap.yaml`: Comment out or remove the `ssl_cert` and `ssl_key` lines
4. `phpmyadmin/deployment.yaml`: Remove the `tls.crt` and `tls.key` items from the `mysql-phpmyadmin-client-certs` volume

### Downgrade to TCP (no encryption)
Perform all the TLS downgrade steps above, then additionally:
1. `mysql/configmap.yaml`: Remove `ssl_ca`, `ssl_cert`, `ssl_key` lines from both primary.cnf and replica.cnf. In primary.sql, change `REQUIRE SSL` to nothing. In secondary.sql, remove `MASTER_SSL_CA`, `MASTER_SSL`, and `MASTER_SSL_VERIFY_SERVER_CERT` lines
2. `openemr/deployment.yaml`: Remove the `FORCE_DATABASE_SSL_CONNECT` environment variable and remove the entire `mysql-openemr-client-certs` volume and volumeMount
3. `phpmyadmin/configmap.yaml`: Set `ssl` to `false`, remove `ssl_ca`, and remove `ssl_verify`
4. `phpmyadmin/deployment.yaml`: Remove the entire `mysql-phpmyadmin-client-certs` volume and volumeMount
5. `certs/mysql.yaml`, `certs/mysql-replication.yaml`, `certs/mysql-openemr-client.yaml`, `certs/mysql-phpmyadmin-client.yaml`: These cert-manager Certificate resources can be removed entirely
6. `kub-up` and `kub-down` (and `.bat` variants): Remove the mysql cert references

## Redis Connection Security
By default, Redis connections use **mTLS (mutual TLS)** with X509 client certificate verification. OpenEMR uses phpredis with Sentinel discovery for automatic failover (`SESSION_STORAGE_MODE=predis-sentinel`). All certificates are managed by cert-manager. To downgrade the connection security:

### Downgrade to TLS (encrypted, no client certs)
1. `redis/configmap-main.yaml`: Change `tls-auth-clients yes` to `tls-auth-clients no`
2. `redis/statefulset-redis.yaml`: Change `REDISX509=true` to `REDISX509=false`
3. `redis/statefulset-sentinel.yaml`: Change `REDISX509=true` to `REDISX509=false` and change `tls-auth-clients yes` to `tls-auth-clients no`
4. `openemr/deployment.yaml`: Remove the `REDIS_X509` environment variable and remove the client cert/key items (`redis-master-cert`, `redis-master-key`, `redis-sentinel-cert`, `redis-sentinel-key`) from the `redis-openemr-client-certs` volume

### Downgrade to TCP (no encryption)
Perform all the TLS downgrade steps above, then additionally:
1. `redis/configmap-main.yaml`: Remove all `tls-*` lines, change `port 0` to `port 6379`, and remove `tls-port 6379`
2. `redis/statefulset-redis.yaml`: Remove the `TLSPARAMETERS` variable and its usage in redis-cli commands, and remove the `redis-certs` volume and volumeMount
3. `redis/statefulset-sentinel.yaml`: Remove the `TLSPARAMETERS` variable and its usage in redis-cli commands, remove the `sentinel-certs` volume and volumeMount, and remove all `tls-*` lines from the sentinel config generation
4. `openemr/deployment.yaml`: Remove the `REDIS_TLS`, `REDIS_X509`, and `REDIS_TLS_CERT_KEY_PATH` environment variables and remove the entire `redis-openemr-client-certs` volume and volumeMount
5. `certs/redis.yaml`, `certs/redis-openemr-client.yaml`, `certs/sentinel.yaml`: These cert-manager Certificate resources can be removed entirely
6. `kub-up` and `kub-down` (and `.bat` variants): Remove the redis/sentinel cert references

# Use
1. Install (and then start) Kubernetes with Minikube or Kind or other.
    - For Minikube or other, can find online documentation.
    - For Kind, see below for instructions sets with 1 node or 4 nodes.
        - 1 node:
            ```bash
            kind create cluster --config kind-config-1-node.yaml
            ```
        - 4 nodes (1 control-plane node and 3 worker nodes). Shared volumes use an in-cluster NFS provisioner (deployed by kub-up) so pods on different nodes can share ReadWriteMany volumes:
            ```bash
            kind create cluster --config kind-config-4-nodes.yaml
            ```
            - After you run the kub-up command below, here is a neat command to show which nodes the pods are in
                ```bash
                kubectl get pod -o wide
                ```
2. To start OpenEMR orchestration:
    ```bash
    bash kub-up
    ```
3. Can see overall progress with following command:
    ```bash
    kubectl get all
    ```
      - It will look something like this when completed:
          ```console
          NAME                              READY   STATUS    RESTARTS   AGE
          pod/mysql-sts-0                   1/1     Running   0          111s
          pod/mysql-sts-1                   1/1     Running   0          91s
          pod/openemr-7889cf48d8-9jdfl      1/1     Running   0          111s
          pod/openemr-7889cf48d8-qphrw      1/1     Running   0          111s
          pod/openemr-7889cf48d8-zlx9f      1/1     Running   0          111s
          pod/phpmyadmin-f4d9bfc69-rx82d    1/1     Running   0          111s
          pod/redis-0                       1/1     Running   0          111s
          pod/redis-1                       1/1     Running   0          77s
          pod/redis-2                       1/1     Running   0          55s
          pod/sentinel-0                    1/1     Running   0          111s
          pod/sentinel-1                    1/1     Running   0          34s
          pod/sentinel-2                    1/1     Running   0          30s

          NAME                 TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)                         AGE
          service/kubernetes   ClusterIP      10.96.0.1      <none>        443/TCP                         3m40s
          service/mysql        ClusterIP      None           <none>        3306/TCP                        111s
          service/openemr      NodePort       10.96.6.51     <none>        8080:30080/TCP,8090:30443/TCP   111s
          service/phpmyadmin   ClusterIP      10.96.64.163   <none>        8081/TCP,8091/TCP               111s
          service/redis        ClusterIP      None           <none>        6379/TCP                        111s
          service/sentinel     ClusterIP      None           <none>        26379/TCP                       111s

          NAME                         READY   UP-TO-DATE   AVAILABLE   AGE
          deployment.apps/openemr      3/3     3            3           111s
          deployment.apps/phpmyadmin   1/1     1            1           111s

          NAME                                    DESIRED   CURRENT   READY   AGE
          replicaset.apps/openemr-7889cf48d8      3         3         3       111s
          replicaset.apps/phpmyadmin-f4d9bfc69    1         1         1       111s

          NAME                         READY   AGE
          statefulset.apps/mysql-sts   2/2     111s
          statefulset.apps/redis       3/3     111s
          statefulset.apps/sentinel    3/3     111s
          ```
4. Getting the url link to OpenEMR:
    - If using kind with the provided config files, OpenEMR is mapped to localhost: `http://localhost:8800` or `https://localhost:9800`
    - If using minikube:
        ```bash
        minikube service openemr --url
        ```
5. Accessing phpMyAdmin:
    - phpMyAdmin is not exposed externally for security. Access it via port-forward:
        ```bash
        kubectl port-forward service/phpmyadmin 8081:8081
        ```
        Then navigate to `http://localhost:8081`. Press `Ctrl+C` to stop the port-forward when done.
6. Some cool replicas stuff with OpenEMR. The OpenEMR docker pods are run as a replica set (since it is set to 3 replicas in this OpenEMR deployment script). Gonna cover how to view the replica set and how to change the number of replicas on the fly in this step.
    - First. lets list the replica set like this:
        ```bash
        kubectl get rs
        ```
        - It will look something like this (note OpenEMR has 3 desired and 3 current replicas going):
            ```console
            NAME                    DESIRED   CURRENT   READY   AGE
            openemr-7889cf48d8      3         3         3       9m22s
            phpmyadmin-f4d9bfc69    1         1         1       9m22s
            ```
    - Second, lets increase OpenEMR's replicas from 3 to 10 (ie. pretend in an environment where a huge number of OpenEMR users are using the system at the same time)
        ```bash
        kubectl scale deployment.apps/openemr --replicas=10
        ```
        - It will return the following:
            ```console
            deployment.apps/openemr scaled
            ```
        - Now, there are 10 replicas of OpenEMR instead of 3. Enter the `kubectl get rs` and `kubectl get pod` to see what happened.
    - Third, lets decrease OpenEMR's replicas from 10 to 5 (ie. pretend in an environment where don't need to expend resources of offering 10 replicas, and can drop to 5 replicas)
        ```bash
        kubectl scale deployment.apps/openemr --replicas=5
        ```
        - It will return the following:
            ```console
            deployment.apps/openemr scaled
            ```
        - Now, there are 5 replicas of OpenEMR instead of 10. Enter the `kubectl get rs` and `kubectl get pod` to see what happened.
    - This is just a quick overview of scaling. Note we just did manual scaling in the example above, but there are also options of automatic scaling for example depending on cpu use etc.
7. Some cool replicas stuff with MariaDB. 2 statefulset replications of MariaDB (1 primary/master with 1 replica/slave) are created by default. The number of replicas can be increased or decreased.
    - Increase replicas (after this command will have the 1 primary/master with 3 replicas/slaves).
        ```bash
        kubectl scale sts mysql-sts --replicas=4
        ```
    - Decrease replicas (after this command will have the 1 primary/master with 2 replicas/slaves).
        ```bash
        kubectl scale sts mysql-sts --replicas=3
        ```
8. Testing Redis Sentinel failover. Redis is configured with automatic failover via Sentinel. To test it:
    - First, check which Redis pod is the current master:
        ```bash
        kubectl exec redis-0 -- redis-cli --tls --cacert /certs/ca.crt --cert /certs/tls.crt --key /certs/tls.key --user admin -a adminpassword info replication | grep role
        ```
    - Delete the master pod to simulate a failure:
        ```bash
        kubectl delete pod redis-0
        ```
    - Watch the sentinel logs to see the failover happen (~1 second):
        ```bash
        kubectl logs sentinel-0 | grep failover
        ```
    - Verify a new master was promoted:
        ```bash
        kubectl exec redis-1 -- redis-cli --tls --cacert /certs/ca.crt --cert /certs/tls.crt --key /certs/tls.key --user admin -a adminpassword info replication | grep role
        ```
    - OpenEMR continues working throughout the failover — the Sentinel-based session handler automatically discovers the new master.
9. To stop and remove OpenEMR orchestration (this will delete everything):
    ```bash
    bash kub-down
    ```
    - For Kind, also need to delete the cluster:
        ````bash
        kind delete cluster
        ````
