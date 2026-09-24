#!/usr/bin/env python3
"""Run SSH integration against a disposable local sshd and existing MySQL fixture.
Never prints credential values. Generates/cleans its own keys and known_hosts.
Requires the current user to be permitted to run /usr/sbin/sshd on a high port.
"""
import json, os, pathlib, pwd, socket, subprocess, tempfile, time

def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

with tempfile.TemporaryDirectory(prefix='luckysql-ssh-test-') as root:
    path = pathlib.Path(root)
    run('/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(path/'host'))
    run('/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', 'fixture-passphrase', '-f', str(path/'client'))
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
    user = pwd.getpwuid(os.getuid()).pw_name
    config = path/'sshd_config'
    config.write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {path/'host'}
PidFile {path/'pid'}
AuthorizedKeysFile {path/'client.pub'}
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowUsers {user}
AllowTcpForwarding yes
LogLevel ERROR
''')
    public = (path/'host.pub').read_text().split()
    (path/'known_hosts').write_text(f'[127.0.0.1]:{port} {public[0]} {public[1]}\n')
    with open(path/'sshd.log','w+') as logs:
        sshd = subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(config)],stdout=logs,stderr=logs)
        try:
            time.sleep(.3)
            if sshd.poll() is not None:
                logs.seek(0); raise RuntimeError('Fixture sshd failed: '+logs.read())
            info=json.loads(subprocess.check_output(['docker','inspect','luckysql-mysql56']))[0]
            values=dict(x.split('=',1) for x in info['Config']['Env'] if '=' in x)
            env=os.environ.copy()
            env.update(DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer', LUCKYSQL_TEST_PORT='3306',
                       LUCKYSQL_TEST_USER=values.get('MYSQL_USER','root'), LUCKYSQL_TEST_PASSWORD=values.get('MYSQL_PASSWORD',values.get('MYSQL_ROOT_PASSWORD','')),
                       LUCKYSQL_TEST_SSH_PORT=str(port),LUCKYSQL_TEST_SSH_USER=user,LUCKYSQL_TEST_SSH_KEY=str(path/'client'),LUCKYSQL_TEST_SSH_HOSTS=str(path/'known_hosts'))
            run('swift','test','--filter','RemoteConnectionTests',env=env)
        finally:
            sshd.terminate(); sshd.wait(timeout=5)
