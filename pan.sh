#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting Premium Control Panel Installation...${NC}"

# Configuration
PANEL_DIR="/usr/local/panel"
PANEL_PORT=7868
PANEL_USER="admin"
# Generate random admin password
PANEL_PASS=$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-12)
PHP_BIN="/usr/local/lsws/lsphp74/bin/php"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

# Install required packages
echo -e "${YELLOW}Installing required packages...${NC}"
yum install -y mariadb-server mariadb wget openssl >/dev/null 2>&1 || apt-get install -y mariadb-server mariadb-client wget openssl >/dev/null 2>&1

# Start and enable MariaDB
if ! systemctl is-active --quiet mariadb; then
    echo -e "${YELLOW}Starting MariaDB...${NC}"
    systemctl start mariadb
    systemctl enable mariadb >/dev/null 2>&1
fi

# Generate random MySQL password
MYSQL_ROOT_PASS=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)

# Secure MariaDB installation
echo -e "${YELLOW}Securing MariaDB...${NC}"
mysql -u root <<EOF 2>/dev/null || true
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASS';
FLUSH PRIVILEGES;
EOF

# Create panel directory
echo -e "${YELLOW}Creating panel directories...${NC}"
mkdir -p "$PANEL_DIR"/{sessions,logs,phpmyadmin,phpmyadmin/tmp}
mkdir -p /tmp/phpmyadmin/{upload,save,temp}
chmod 777 /tmp/phpmyadmin/{upload,save,temp}
chmod 777 "$PANEL_DIR/phpmyadmin/tmp"

# Setup sudoers
echo -e "${YELLOW}Configuring sudoers...${NC}"
cat > /etc/sudoers.d/panel << 'EOF'
nobody ALL=(ALL) NOPASSWD: /usr/local/bin/star
lsadm ALL=(ALL) NOPASSWD: /usr/local/bin/star
nobody ALL=(ALL) NOPASSWD: /bin/rm
lsadm ALL=(ALL) NOPASSWD: /bin/rm
EOF
chmod 440 /etc/sudoers.d/panel

# Install phpMyAdmin
echo -e "${YELLOW}Installing phpMyAdmin...${NC}"
if [ ! -f "$PANEL_DIR/phpmyadmin/index.php" ]; then
    cd /tmp
    wget -q https://files.phpmyadmin.net/phpMyAdmin/5.2.1/phpMyAdmin-5.2.1-all-languages.tar.gz
    tar xzf phpMyAdmin-5.2.1-all-languages.tar.gz
    mv phpMyAdmin-5.2.1-all-languages/* "$PANEL_DIR/phpmyadmin/"
    rm -rf phpMyAdmin-5.2.1-all-languages*
fi

# Create phpMyAdmin config
BLOWFISH_SECRET=$(openssl rand -base64 32)
cat > "$PANEL_DIR/phpmyadmin/config.inc.php" << EOF
<?php
\$cfg['blowfish_secret'] = '$BLOWFISH_SECRET';
\$i = 0;
\$i++;
\$valid = isset(\$_COOKIE['panel_verified']) && 
         \$_COOKIE['panel_verified'] === md5('secret_key_' . date('Y-m-d-H'));
if (\$valid) {
    \$cfg['Servers'][\$i]['auth_type'] = 'config';
    \$cfg['Servers'][\$i]['user'] = 'root';
    \$cfg['Servers'][\$i]['password'] = '$MYSQL_ROOT_PASS';
} else {
    \$cfg['Servers'][\$i]['auth_type'] = 'cookie';
}
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][\$i]['port'] = '3306';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['UploadDir'] = '/tmp/phpmyadmin/upload';
\$cfg['SaveDir'] = '/tmp/phpmyadmin/save';
\$cfg['TempDir'] = '/tmp/phpmyadmin/temp';
\$cfg['LoginCookieValidity'] = 1440;
\$cfg['DefaultLang'] = 'en';
\$cfg['DefaultConnectionCollation'] = 'utf8mb4_unicode_ci';
\$cfg['MaxRows'] = 25;
\$cfg['ShowPhpInfo'] = false;
\$cfg['SendErrorReports'] = 'never';
\$cfg['VersionCheck'] = false;
\$cfg['ShowGitRevision'] = false;
\$cfg['ShowStats'] = false;
\$cfg['ShowServerInfo'] = false;
\$cfg['Servers'][\$i]['hide_db'] = '^(information_schema|performance_schema|mysql|sys)$';
\$cfg['Servers'][\$i]['verbose'] = 'Local MySQL Server';
?>
EOF

echo -e "${YELLOW}Creating panel files...${NC}"

# Create config.php with random password
cat > "$PANEL_DIR/config.php" << 'CONFIGEOF'
<?php
session_start();

$pma_content = file_get_contents(__DIR__ . '/phpmyadmin/config.inc.php');
preg_match("/\['password'\]\s*=\s*'([^']+)'/", $pma_content, $match);
$mysql_pass = $match[1];

define('ADMIN_USER', 'PANEL_USER_PLACEHOLDER');
define('ADMIN_PASS', 'PANEL_PASS_PLACEHOLDER');
define('MYSQL_ROOT_PASS', $mysql_pass);

// Database connection
$conn = @new mysqli('localhost', 'root', MYSQL_ROOT_PASS, 'mysql');

// Check if logged in
function isLoggedIn() {
    return isset($_SESSION['logged_in']) && $_SESSION['logged_in'] === true;
}

// Require login
function requireLogin() {
    if (!isLoggedIn()) {
        header('Location: login.php');
        exit();
    }
}

// Get all domains from /home directory
function getDomains() {
    $domains = [];
    $dirs = @scandir('/home');
    if ($dirs) {
        foreach ($dirs as $dir) {
            if ($dir != '.' && $dir != '..' && is_dir('/home/' . $dir . '/public_html')) {
                $domains[] = $dir;
            }
        }
    }
    return $domains;
}

// Get all databases
function getDatabases() {
    global $conn;
    $databases = [];
    if ($conn && !$conn->connect_error) {
        $result = $conn->query("SELECT DISTINCT Db, User, Host FROM mysql.db WHERE Db NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys', 'panel', 'test')");
        if ($result) {
            while ($row = $result->fetch_assoc()) {
                $databases[] = [
                    'name' => $row['Db'],
                    'user' => $row['User'],
                    'host' => $row['Host']
                ];
            }
        }
    }
    return $databases;
}

// Get server stats
function getServerStats() {
    $stats = [];
    $load = sys_getloadavg();
    $stats['load'] = round($load[0], 2);
    
    $memory = shell_exec("free -m | grep Mem");
    preg_match_all('/\d+/', $memory, $matches);
    $stats['memory_used'] = $matches[0][1] ?? 0;
    $stats['memory_total'] = $matches[0][0] ?? 1;
    $stats['memory_percent'] = round(($stats['memory_used'] / $stats['memory_total']) * 100);
    
    $disk = shell_exec("df -h / | tail -1");
    $parts = preg_split('/\s+/', $disk);
    $stats['disk_used'] = $parts[2] ?? '0G';
    $stats['disk_total'] = $parts[1] ?? '0G';
    $stats['disk_percent'] = str_replace('%', '', $parts[4] ?? '0');
    
    return $stats;
}
?>
CONFIGEOF

# Replace placeholders with actual values
sed -i "s/PANEL_USER_PLACEHOLDER/$PANEL_USER/g" "$PANEL_DIR/config.php"
sed -i "s/PANEL_PASS_PLACEHOLDER/$PANEL_PASS/g" "$PANEL_DIR/config.php"

# Create login.php
cat > "$PANEL_DIR/login.php" << 'LOGINEOF'
<?php
require_once 'config.php';

if (isLoggedIn()) {
    header('Location: index.php');
    exit();
}

$error = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $username = $_POST['username'] ?? '';
    $password = $_POST['password'] ?? '';
    
    // Check hardcoded credentials
    if ($username === ADMIN_USER && $password === ADMIN_PASS) {
        $_SESSION['logged_in'] = true;
        header('Location: index.php');
        exit();
    } else {
        $error = 'Invalid credentials';
    }
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Login - Control Panel</title>
    <link rel="stylesheet" href="style.css">
</head>
<body class="login-page">
    <div class="login-container">
        <div class="login-box">
            <div class="brand">
                <h1>Control Panel</h1>
                <p>Server Management System</p>
            </div>
            <?php if ($error): ?>
                <div class="alert error"><?php echo $error; ?></div>
            <?php endif; ?>
            <form method="POST">
                <input type="text" name="username" placeholder="Username" required autofocus>
                <input type="password" name="password" placeholder="Password" required>
                <button type="submit">Sign In</button>
            </form>
        </div>
    </div>
</body>
</html>
LOGINEOF

# Create logout.php
cat > "$PANEL_DIR/logout.php" << 'LOGOUTEOF'
<?php
session_start();
session_destroy();
header('Location: login.php');
exit();
?>
LOGOUTEOF

# Create pma.php
cat > "$PANEL_DIR/pma.php" << 'PMAEOF'
<?php
session_start();
if (!isset($_SESSION['logged_in']) || $_SESSION['logged_in'] !== true) {
    die('Access denied');
}

// Set a cookie that phpMyAdmin config can check
setcookie('panel_verified', md5('secret_key_' . date('Y-m-d-H')), time()+300, '/');
header('Location: phpmyadmin/');
PMAEOF

# Create index.php (truncated for space - you'll need to add the full content)
cat > "$PANEL_DIR/index.php" << 'INDEXEOF'
<?php
require_once 'config.php';
requireLogin();

$page = $_GET['page'] ?? 'dashboard';
$message = '';
$error = '';

$server_ip = trim(shell_exec('hostname -I | cut -d" " -f1'));

// Handle domain creation
if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['action'])) {
    
    if ($_POST['action'] === 'create_domains') {
        $domains = trim($_POST['domains']);
        if ($domains) {
            $domain_list = explode("\n", str_replace(["\r\n", "\r"], "\n", $domains));
            $domain_list = array_filter(array_map('trim', $domain_list)); 
            $input_string = implode("\n", $domain_list) . "\n\n";
            $output = shell_exec("echo '" . addslashes($input_string) . "' | sudo /usr/local/bin/star -createbulk 2>&1");
            $message = 'Domains created successfully!';
        }
    } elseif ($_POST['action'] === 'delete_domain') {
        $domain = $_POST['domain'];
        shell_exec("sudo /usr/local/bin/star -delete $domain 2>&1");
        $message = 'Domain deleted successfully!';
    } elseif ($_POST['action'] === 'create_database') {
        $db_name = preg_replace('/[^a-zA-Z0-9_]/', '', $_POST['db_name']);
        $db_user = preg_replace('/[^a-zA-Z0-9_]/', '', $_POST['db_user']);
        $db_pass = $_POST['db_pass'];
        
        if ($conn && !$conn->connect_error) {
            $conn->query("CREATE DATABASE IF NOT EXISTS `$db_name`");
            $conn->query("CREATE USER IF NOT EXISTS '$db_user'@'localhost' IDENTIFIED BY '$db_pass'");
            $conn->query("GRANT ALL PRIVILEGES ON `$db_name`.* TO '$db_user'@'localhost'");
            $conn->query("FLUSH PRIVILEGES");
            $message = 'Database created successfully!';
        } else {
            $error = 'Database connection failed!';
        }

    } elseif ($_POST['action'] === 'change_db_password') {
        $db_user = $_POST['db_user'];
        $new_password = $_POST['new_password'];
        
        if ($conn && !$conn->connect_error) {
            $conn->query("ALTER USER '$db_user'@'localhost' IDENTIFIED BY '$new_password'");
            $conn->query("FLUSH PRIVILEGES");
            $message = "Password changed successfully for user: $db_user";
        } else {
            $error = 'Database connection failed!';
        }
        
    } elseif ($_POST['action'] === 'delete_database') {
        $db_name = $_POST['db_name'];
        $db_user = $_POST['db_user'];
        $admin_password = $_POST['admin_password'] ?? '';
        
        if ($admin_password !== ADMIN_PASS) {
            $error = 'Invalid admin password!';
        } else {
            if ($conn && !$conn->connect_error) {
                $conn->query("DROP DATABASE IF EXISTS `$db_name`");
                $conn->query("DROP USER IF EXISTS '$db_user'@'localhost'");
                $conn->query("FLUSH PRIVILEGES");
                $message = "Database $db_name and user $db_user deleted successfully!";
            } else {
                $error = 'Database connection failed!';
            }
        }
    }
}

$stats = getServerStats();
$domains = getDomains();
$databases = getDatabases();
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Control Panel</title>
    <link rel="stylesheet" href="style.css">
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <script src="https://cdn.jsdelivr.net/npm/sweetalert2@11"></script>
</head>
<body>
    <nav class="navbar">
        <div class="nav-brand">
            <h2><a href="index.php" style="color: inherit; text-decoration: none;">Control Panel</a></h2>
        </div>
        <div class="nav-menu">
            <a href="?page=dashboard" class="<?php echo $page === 'dashboard' ? 'active' : ''; ?>">Dashboard</a>
            <a href="?page=domains" class="<?php echo $page === 'domains' ? 'active' : ''; ?>">Domains</a>
            <a href="?page=databases" class="<?php echo $page === 'databases' ? 'active' : ''; ?>">Databases</a>
            <a href="http://<?php echo $server_ip ?>:9999" target="_blank">File Manager</a>
            <a href="logout.php" class="logout">Logout</a>
        </div>
    </nav>

    <div class="container">
        <?php if ($message): ?>
            <script>
                Swal.fire({
                    icon: 'success',
                    title: 'Success',
                    text: '<?php echo addslashes($message); ?>',
                    timer: 3000,
                    showConfirmButton: false
                });
            </script>
        <?php endif; ?>
        <?php if ($error): ?>
            <script>
                Swal.fire({
                    icon: 'error',
                    title: 'Error',
                    text: '<?php echo addslashes($error); ?>'
                });
            </script>
        <?php endif; ?>

        <?php if ($page === 'dashboard'): ?>
            <div class="stats-grid">
                <div class="stat-card">
                    <div class="stat-value"><?php echo $stats['load']; ?></div>
                    <div class="stat-label">Server Load</div>
                </div>
                <div class="stat-card">
                    <div class="stat-value"><?php echo $stats['memory_percent']; ?>%</div>
                    <div class="stat-label">Memory Usage</div>
                    <div class="stat-bar">
                        <div class="stat-bar-fill" style="width: <?php echo $stats['memory_percent']; ?>%"></div>
                    </div>
                </div>
                <div class="stat-card">
                    <div class="stat-value"><?php echo $stats['disk_percent']; ?>%</div>
                    <div class="stat-label">Disk Usage</div>
                    <div class="stat-bar">
                        <div class="stat-bar-fill" style="width: <?php echo $stats['disk_percent']; ?>%"></div>
                    </div>
                </div>
                <div class="stat-card">
                    <div class="stat-value"><?php echo count($domains); ?></div>
                    <div class="stat-label">Total Domains</div>
                </div>
            </div>

            <div class="grid">
                <div class="card">
                    <h3>Quick Stats</h3>
                    <table class="info-table">
                        <tr><td>Total Domains</td><td><?php echo count($domains); ?></td></tr>
                        <tr><td>Total Databases</td><td><?php echo count($databases); ?></td></tr>
                        <tr><td>PHP Version</td><td>7.4</td></tr>
                        <tr><td>Web Server</td><td>OpenLiteSpeed</td></tr>
                        <tr><td>Memory</td><td><?php echo $stats['memory_used'] . ' / ' . $stats['memory_total']; ?> MB</td></tr>
                        <tr><td>Disk</td><td><?php echo $stats['disk_used'] . ' / ' . $stats['disk_total']; ?></td></tr>
                    </table>
                </div>
                <div class="card">
                    <h3>Quick Actions</h3>
                    <div class="button-group">
                        <a href="?page=domains" class="btn btn-primary">Manage Domains</a>
                        <a href="?page=databases" class="btn btn-primary">Manage Databases</a>
                        <a href="pma.php" target="_blank" class="btn btn-secondary">Open phpMyAdmin</a>
                        <a href="http://<?php echo $server_ip ?>:9999" target="_blank" class="btn btn-secondary">File Manager</a>
                    </div>
                </div>
            </div>

        <?php elseif ($page === 'domains'): ?>
            <div class="page-header">
                <h1>Domain Management</h1>
            </div>

            <div class="card">
                <h3>Create Domains (Bulk)</h3>
                <form method="POST">
                    <input type="hidden" name="action" value="create_domains">
                    <textarea name="domains" rows="5" placeholder="Enter domains (one per line)&#10;example1.com&#10;example2.com" required></textarea>
                    <button type="submit" class="btn btn-primary">Create Domains</button>
                </form>
            </div>

            <div class="card">
                <h3>Existing Domains (<?php echo count($domains); ?>)</h3>
                <div class="table-container">
                    <table>
                        <thead>
                            <tr>
                                <th>Domain</th>
                                <th>Path</th>
                                <th>Actions</th>
                            </tr>
                        </thead>
                        <tbody>
                            <?php foreach ($domains as $domain): ?>
                            <tr>
                                <td><?php echo htmlspecialchars($domain); ?></td>
                                <td>/home/<?php echo htmlspecialchars($domain); ?>/public_html</td>
                                <td>
                                    <div class="action-buttons">
                                        <a href="http://<?php echo $domain; ?>" target="_blank" class="btn btn-sm">Visit</a>
                                        <form method="POST" style="display: inline;" onsubmit="return confirm('Delete this domain?');">
                                            <input type="hidden" name="action" value="delete_domain">
                                            <input type="hidden" name="domain" value="<?php echo $domain; ?>">
                                            <button type="submit" class="btn btn-sm btn-danger">Delete</button>
                                        </form>
                                    </div>
                                </td>
                            </tr>
                            <?php endforeach; ?>
                            <?php if (empty($domains)): ?>
                            <tr>
                                <td colspan="3" class="text-center">No domains found. Create your first domain above.</td>
                            </tr>
                            <?php endif; ?>
                        </tbody>
                    </table>
                </div>
            </div>

        <?php elseif ($page === 'databases'): ?>
            <div class="page-header">
                <h1>Database Management</h1>
                <a href="pma.php" target="_blank" class="btn btn-primary" style="float: right;">Open phpMyAdmin as Root</a>
            </div>

            <div class="card">
                <h3>Create Database</h3>
                <form method="POST" class="form-inline">
                    <input type="hidden" name="action" value="create_database">
                    <input type="text" name="db_name" placeholder="Database Name" pattern="[a-zA-Z0-9_]+" required>
                    <input type="text" name="db_user" placeholder="Username" pattern="[a-zA-Z0-9_]+" required>
                    <input type="password" name="db_pass" placeholder="Password" required>
                    <button type="submit" class="btn btn-primary">Create Database</button>
                </form>
            </div>

            <div class="card">
                <h3>Existing Databases (<?php echo count($databases); ?>)</h3>
                <div class="table-container">
                    <table>
                        <thead>
                            <tr>
                                <th>Database</th>
                                <th>User</th>
                                <th>Host</th>
                                <th>Actions</th>
                            </tr>
                        </thead>
                        <tbody>
                            <?php foreach ($databases as $db): ?>
                            <tr>
                                <td><?php echo htmlspecialchars($db['name']); ?></td>
                                <td><?php echo htmlspecialchars($db['user']); ?></td>
                                <td><?php echo htmlspecialchars($db['host']); ?></td>
                                <td>
                                    <button onclick="showPasswordModal('<?php echo $db['user']; ?>')" class="btn btn-sm btn-secondary">Change Password</button>
                                    <button onclick="showDeleteModal('<?php echo $db['name']; ?>', '<?php echo $db['user']; ?>')" class="btn btn-sm btn-danger">Delete</button>
                                </td>
                            </tr>
                            <?php endforeach; ?>
                            <?php if (empty($databases)): ?>
                            <tr>
                                <td colspan="4" class="text-center">No databases found. Create your first database above.</td>
                            </tr>
                            <?php endif; ?>
                        </tbody>
                    </table>
                </div>
            </div>

            <!-- Bootstrap Modal for Password Change -->
            <div class="modal fade" id="passwordModal" tabindex="-1">
                <div class="modal-dialog">
                    <div class="modal-content">
                        <div class="modal-header">
                            <h5 class="modal-title">Change Database Password</h5>
                            <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
                        </div>
                        <form method="POST">
                            <div class="modal-body">
                                <input type="hidden" name="action" value="change_db_password">
                                <input type="hidden" name="db_user" id="modal_user" value="">
                                <div class="mb-3">
                                    <label class="form-label">User: <span id="modal_user_display"></span></label>
                                </div>
                                <div class="mb-3">
                                    <label class="form-label">New Password:</label>
                                    <input type="password" class="form-control" name="new_password" required>
                                </div>
                            </div>
                            <div class="modal-footer">
                                <button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button>
                                <button type="submit" class="btn btn-primary">Change Password</button>
                            </div>
                        </form>
                    </div>
                </div>
            </div>

            <!-- Bootstrap Modal for Database Deletion -->
            <div class="modal fade" id="deleteModal" tabindex="-1">
                <div class="modal-dialog">
                    <div class="modal-content">
                        <div class="modal-header">
                            <h5 class="modal-title">Delete Database</h5>
                            <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
                        </div>
                        <form method="POST">
                            <div class="modal-body">
                                <input type="hidden" name="action" value="delete_database">
                                <input type="hidden" name="db_name" id="delete_modal_db_name" value="">
                                <input type="hidden" name="db_user" id="delete_modal_db_user" value="">
                                
                                <div class="alert alert-danger">
                                    <strong>Warning!</strong> This action cannot be undone!
                                </div>
                                
                                <div class="mb-3">
                                    <label class="form-label">Database: <strong id="delete_db_display"></strong></label>
                                </div>
                                <div class="mb-3">
                                    <label class="form-label">User: <strong id="delete_user_display"></strong></label>
                                </div>
                                <hr>
                                <div class="mb-3">
                                    <label class="form-label">Enter Admin Password to Confirm:</label>
                                    <input type="password" class="form-control" name="admin_password" required placeholder="Admin password">
                                </div>
                            </div>
                            <div class="modal-footer">
                                <button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button>
                                <button type="submit" class="btn btn-danger">Delete Database</button>
                            </div>
                        </form>
                    </div>
                </div>
            </div>

            <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
            
            <script>
            function showPasswordModal(user) {
                document.getElementById('modal_user').value = user;
                document.getElementById('modal_user_display').textContent = user;
                var modal = new bootstrap.Modal(document.getElementById('passwordModal'));
                modal.show();
            }
            
            function showDeleteModal(dbName, dbUser) {
                document.getElementById('delete_modal_db_name').value = dbName;
                document.getElementById('delete_modal_db_user').value = dbUser;
                document.getElementById('delete_db_display').textContent = dbName;
                document.getElementById('delete_user_display').textContent = dbUser;
                var modal = new bootstrap.Modal(document.getElementById('deleteModal'));
                modal.show();
            }
            </script>
        <?php endif; ?>
    </div>
</body>
</html>
INDEXEOF

# Create style.css
cat > "$PANEL_DIR/style.css" << 'STYLEEOF'
* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
    background: #f5f5f5;
    color: #333;
    line-height: 1.6;
}

.login-page {
    background: linear-gradient(135deg, #673ab7 0%, #512da8 100%);
    display: flex;
    align-items: center;
    justify-content: center;
    min-height: 100vh;
}

.login-container {
    width: 100%;
    max-width: 400px;
    padding: 20px;
}

.login-box {
    background: white;
    padding: 40px;
    border-radius: 10px;
    box-shadow: 0 10px 40px rgba(0,0,0,0.2);
}

.brand {
    text-align: center;
    margin-bottom: 30px;
}

.brand h1 {
    color: #673ab7;
    font-size: 28px;
    margin-bottom: 5px;
}

.brand p {
    color: #999;
    font-size: 14px;
}

.login-box input {
    width: 100%;
    padding: 12px;
    margin-bottom: 15px;
    border: 1px solid #ddd;
    border-radius: 5px;
    font-size: 14px;
    transition: border 0.3s;
}

.login-box input:focus {
    outline: none;
    border-color: #673ab7;
}

.login-box button {
    width: 100%;
    padding: 12px;
    background: #673ab7;
    color: white;
    border: none;
    border-radius: 5px;
    font-size: 16px;
    font-weight: 600;
    cursor: pointer;
    transition: background 0.3s;
}

.login-box button:hover {
    background: #512da8;
}

.navbar {
    background: white !important;
    padding: 0 30px !important;
    box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    display: flex;
    justify-content: space-between;
    align-items: center;
    height: 60px;
    border-radius: 0 !important;
}

.nav-brand h2 {
    color: #673ab7;
    font-size: 22px;
    margin: 0;
}

.nav-menu {
    display: flex;
    gap: 5px;
}

.nav-menu a {
    padding: 8px 16px;
    color: #666;
    text-decoration: none;
    border-radius: 5px;
    transition: all 0.3s;
    font-size: 14px;
    font-weight: 500;
}

.nav-menu a:hover {
    background: #f5f5f5;
    color: #673ab7;
}

.nav-menu a.active {
    background: #673ab7;
    color: white;
}

.nav-menu a.logout {
    color: #f44336;
}

.nav-menu a.logout:hover {
    background: #ffebee;
}

.container {
    max-width: 1400px !important;
    margin: 30px auto;
    padding: 0 30px;
}

.alert {
    padding: 12px 20px;
    border-radius: 5px;
    margin-bottom: 20px;
    font-size: 14px;
}

.alert.success {
    background: #e8f5e9;
    color: #2e7d32;
    border: 1px solid #a5d6a7;
}

.alert.error {
    background: #ffebee;
    color: #c62828;
    border: 1px solid #ef9a9a;
}

.stats-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
    gap: 20px;
    margin-bottom: 30px;
}

.stat-card {
    background: white;
    padding: 25px;
    border-radius: 10px;
    box-shadow: none;
    border: 2px solid #e0e0e0;
}

.stat-value {
    font-size: 32px;
    font-weight: 700;
    color: #673ab7;
    margin-bottom: 5px;
}

.stat-label {
    color: #999;
    font-size: 14px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.stat-bar {
    margin-top: 10px;
    height: 6px;
    background: #f0f0f0;
    border-radius: 3px;
    overflow: hidden;
}

.stat-bar-fill {
    height: 100%;
    background: linear-gradient(90deg, #673ab7, #512da8);
    border-radius: 3px;
    transition: width 0.3s;
}

.grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));
    gap: 20px;
}

.card {
    background: white !important;
    padding: 25px !important;
    border-radius: 10px !important;
    box-shadow: none;
    margin-bottom: 20px;
    border: 2px solid #e0e0e0;
}

.card h3 {
    color: #333;
    margin-bottom: 20px;
    font-size: 18px;
    font-weight: 600;
}

.page-header {
    margin-bottom: 30px;
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.page-header h1 {
    color: #333;
    font-size: 28px;
    font-weight: 600;
    margin: 0;
}

.table-container {
    overflow-x: auto;
}

table {
    width: 100%;
    border-collapse: collapse;
}

table th {
    text-align: left;
    padding: 12px;
    background: #f8f8f8;
    color: #666;
    font-weight: 600;
    font-size: 13px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    border-bottom: 2px solid #e0e0e0;
}

table td {
    padding: 12px;
    border-bottom: 1px solid #f0f0f0;
    font-size: 14px;
}

table tbody tr:hover {
    background: #fafafa;
}

.text-center {
    text-align: center;
    color: #999;
}

.info-table {
    width: 100%;
}

.info-table td {
    padding: 10px 0;
    border-bottom: 1px solid #f0f0f0;
}

.info-table td:first-child {
    color: #999;
    font-size: 13px;
}

.info-table td:last-child {
    text-align: right;
    font-weight: 600;
    color: #333;
}

textarea {
    width: 100%;
    padding: 12px;
    border: 1px solid #ddd;
    border-radius: 5px;
    font-size: 14px;
    font-family: monospace;
    resize: vertical;
    margin-bottom: 15px;
}

textarea:focus {
    outline: none;
    border-color: #673ab7;
}

input[type="text"],
input[type="password"] {
    padding: 10px 12px;
    border: 1px solid #ddd;
    border-radius: 5px;
    font-size: 14px;
    margin-right: 10px;
}

input[type="text"]:focus,
input[type="password"]:focus {
    outline: none;
    border-color: #673ab7;
}

.form-inline {
    display: flex;
    gap: 10px;
    flex-wrap: wrap;
}

.form-inline input {
    flex: 1;
    min-width: 150px;
}

.btn {
    display: inline-block;
    padding: 10px 20px !important;
    border: none !important;
    border-radius: 5px !important;
    font-size: 14px !important;
    font-weight: 600 !important;
    cursor: pointer;
    text-decoration: none !important;
    transition: all 0.3s !important;
}

.btn-primary {
    background: #673ab7 !important;
    color: white !important;
}

.btn-primary:hover {
    background: #512da8 !important;
    color: white !important;
}

.btn-secondary {
    background: #757575 !important;
    color: white !important;
}

.btn-secondary:hover {
    background: #616161 !important;
    color: white !important;
}

.btn-danger {
    background: #f44336 !important;
    color: white !important;
}

.btn-danger:hover {
    background: #e53935 !important;
    color: white !important;
}

.btn-sm {
    padding: 6px 12px !important;
    font-size: 13px !important;
}

.button-group {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 10px;
}

.action-buttons {
    display: flex;
    gap: 5px;
}

.modal-content {
    border-radius: 10px !important;
    border: none !important;
}

.modal-header {
    background: #f8f8f8;
    border-bottom: 1px solid #e0e0e0 !important;
    border-radius: 10px 10px 0 0 !important;
}

.modal-title {
    color: #333;
    font-weight: 600;
}

.modal-footer {
    border-top: 1px solid #e0e0e0 !important;
}

.swal2-popup {
    border-radius: 10px !important;
    font-family: inherit !important;
}

.swal2-title {
    color: #333 !important;
    font-size: 24px !important;
}

.swal2-content {
    color: #666 !important;
}

.swal2-confirm {
    background: #673ab7 !important;
    border-radius: 5px !important;
    font-weight: 600 !important;
    padding: 10px 24px !important;
}

.swal2-cancel {
    background: #757575 !important;
    border-radius: 5px !important;
    font-weight: 600 !important;
    padding: 10px 24px !important;
}

.swal2-input {
    border: 1px solid #ddd !important;
    border-radius: 5px !important;
    padding: 10px !important;
}

.swal2-input:focus {
    border-color: #673ab7 !important;
    box-shadow: 0 0 0 3px rgba(103, 58, 183, 0.1) !important;
}

.form-control {
    border: 1px solid #ddd !important;
    border-radius: 5px !important;
}

.form-control:focus {
    border-color: #673ab7 !important;
    box-shadow: 0 0 0 0.2rem rgba(103, 58, 183, 0.25) !important;
}

.form-label {
    color: #555;
    font-weight: 600;
    margin-bottom: 5px;
}

@media (max-width: 768px) {
    .navbar {
        padding: 0 15px !important;
    }
    
    .nav-menu {
        flex-wrap: wrap;
    }
    
    .container {
        padding: 0 15px !important;
    }
    
    .grid {
        grid-template-columns: 1fr;
    }
    
    .stats-grid {
        grid-template-columns: 1fr;
    }
    
    .button-group {
        grid-template-columns: 1fr;
    }
    
    .form-inline {
        flex-direction: column;
    }
    
    .form-inline input {
        width: 100%;
        margin-right: 0;
        margin-bottom: 10px;
    }
    
    .page-header {
        flex-direction: column;
        align-items: flex-start;
    }
    
    .page-header .btn {
        margin-top: 10px;
    }
}
STYLEEOF

# Set permissions
chown -R nobody:nobody "$PANEL_DIR"
chmod 755 "$PANEL_DIR"
chmod 777 "$PANEL_DIR/sessions"

# Create systemd service
echo -e "${YELLOW}Creating systemd service...${NC}"
cat > /etc/systemd/system/panel.service << EOF
[Unit]
Description=Premium Control Panel
After=network.target mysql.service

[Service]
Type=simple
User=nobody
WorkingDirectory=$PANEL_DIR
ExecStart=$PHP_BIN -S 0.0.0.0:$PANEL_PORT
Restart=always
RestartSec=10
StandardOutput=append:$PANEL_DIR/logs/access.log
StandardError=append:$PANEL_DIR/logs/error.log
Environment="PHP_CLI_SERVER_WORKERS=4"

[Install]
WantedBy=multi-user.target
EOF

# Start service
systemctl daemon-reload
systemctl enable panel.service >/dev/null 2>&1
systemctl restart panel.service
sleep 3

# Save credentials to file
CREDS_FILE="/root/.panel_credentials"
SERVER_IP=$(hostname -I | awk '{print $1}')
cat > "$CREDS_FILE" << EOF
========================================
Premium Control Panel Credentials
========================================
Panel URL: http://$SERVER_IP:$PANEL_PORT
Panel Username: $PANEL_USER
Panel Password: $PANEL_PASS

phpMyAdmin: http://$SERVER_IP:$PANEL_PORT/phpmyadmin
MySQL Root Password: $MYSQL_ROOT_PASS

Installation Date: $(date)
========================================
EOF
chmod 600 "$CREDS_FILE"

# Display results
clear
echo -e "${GREEN}"
echo "========================================="
echo "✅ Premium Control Panel Setup Complete!"
echo "========================================="
echo -e "${NC}"
echo -e "${YELLOW}📌 Panel Access:${NC}"
echo -e "   URL: ${GREEN}http://$SERVER_IP:$PANEL_PORT${NC}"
echo -e "   Username: ${GREEN}$PANEL_USER${NC}"
echo -e "   Password: ${GREEN}$PANEL_PASS${NC}"
echo ""
echo -e "${YELLOW}📌 phpMyAdmin:${NC}"
echo -e "   URL: ${GREEN}http://$SERVER_IP:$PANEL_PORT/phpmyadmin${NC}"
echo -e "   MySQL Root: ${GREEN}$MYSQL_ROOT_PASS${NC}"
echo ""
echo -e "${YELLOW}📌 Credentials saved to:${NC} ${GREEN}$CREDS_FILE${NC}"
echo -e "${YELLOW}📌 Panel files location:${NC} ${GREEN}$PANEL_DIR${NC}"
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${YELLOW}⚠️  IMPORTANT: Save these credentials in a secure place!${NC}"
echo -e "${GREEN}=========================================${NC}"
