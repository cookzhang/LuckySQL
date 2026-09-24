#!/usr/bin/env python3
"""Disposable MySQL/MariaDB and verified-TLS acceptance fixtures.
All containers have unique names and a fresh tmpfs database. Existing containers
and database volumes are never changed. Synthetic credentials are fixture-only.
"""
import os, pathlib, socket, subprocess, tempfile, time, uuid

def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)
def output(args):
    return subprocess.check_output(args, text=True).strip()
def certificate(root, name, ca=False):
    args=['openssl','req','-new','-newkey','rsa:2048','-nodes','-keyout',str(root/(name+'.key')),'-out',str(root/(name+'.csr')),'-subj','/CN='+('LuckySQL Fixture CA' if ca else 'localhost')]
    run(args,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    args=['openssl','x509','-req','-in',str(root/(name+'.csr')),'-out',str(root/(name+'.pem')),'-days','2']
    if ca: args += ['-signkey',str(root/(name+'.key'))]
    else:
        ext=root/(name+'.ext');ext.write_text('subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth,clientAuth\n')
        args += ['-CA',str(root/'ca.pem'),'-CAkey',str(root/'ca.key'),'-CAcreateserial','-extfile',str(ext)]
    run(args,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    (root/(name+'.key')).chmod(0o644)

images=os.environ.get('LUCKYSQL_MATRIX_IMAGES','mysql:5.7,mysql:8.4').split(',')
for image in images:
    name='luckysql-acceptance-'+uuid.uuid4().hex[:10]
    with tempfile.TemporaryDirectory(prefix='luckysql-cert-') as directory:
        root=pathlib.Path(directory);root.chmod(0o755)
        tls=image.startswith('mysql:8')
        if tls:
            for kind in ['ca','server','client']:certificate(root,kind,ca=kind=='ca')
        env=os.environ.copy();env['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer'
        args=['docker','run','-d','--rm','--name',name,'--tmpfs','/var/lib/mysql','-p','127.0.0.1::3306','-e','MYSQL_ROOT_PASSWORD=fixture-root','-e','MYSQL_DATABASE=luckysql','-e','MYSQL_USER=luckysql','-e','MYSQL_PASSWORD=fixture-password']
        if tls: args += ['-v',str(root)+':/certs:ro']
        args += [image, '--log-bin-trust-function-creators=1', '--max-allowed-packet=67108864']
        if tls: args += ['--ssl-ca=/certs/ca.pem','--ssl-cert=/certs/server.pem','--ssl-key=/certs/server.key']
        try:
            run(args,stdout=subprocess.DEVNULL)
            print('Started isolated fixture:',image,flush=True)
            client='mariadb' if image.startswith('mariadb') else 'mysql'
            for _ in range(120):
                check=subprocess.run(['docker','exec',name,client,'-uroot','-pfixture-root','-e','SELECT 1'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                if check.returncode==0:break
                time.sleep(1)
            else: raise RuntimeError('Database fixture did not start')
            port=output(['docker','port',name,'3306/tcp']).split(':')[-1]
            env.update(LUCKYSQL_TEST_PORT=port,LUCKYSQL_TEST_USER='luckysql',LUCKYSQL_TEST_PASSWORD='fixture-password')
            if tls:
                sql="CREATE USER 'tlsclient'@'%' IDENTIFIED BY 'fixture-password' REQUIRE X509; GRANT ALL ON luckysql.* TO 'tlsclient'@'%';"
                run(['docker','exec','-i',name,client,'-uroot','-pfixture-root'],input=sql,text=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                env.update(LUCKYSQL_TEST_TLS_PORT=port,LUCKYSQL_TEST_TLS_CA=str(root/'ca.pem'),LUCKYSQL_TEST_TLS_CERT=str(root/'client.pem'),LUCKYSQL_TEST_TLS_KEY=str(root/'client.key'))
            label=image.replace(':','-').replace('/','-')
            with open('/tmp/luckysql-matrix-'+label+'.log','w') as log:
                result=subprocess.run(['swift','test'],env=env,stdout=log,stderr=subprocess.STDOUT)
            print(image,'test exit:',result.returncode,'log: /tmp/luckysql-matrix-'+label+'.log',flush=True)
            if result.returncode:raise RuntimeError('Acceptance failed for '+image)
        finally:subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
