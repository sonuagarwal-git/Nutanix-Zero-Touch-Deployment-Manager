// Load environment variables from .env file
require('dotenv').config();

const express = require('express');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');
const WebSocket = require('ws');
const https = require('https');
const session = require('express-session');
const bcrypt = require('bcryptjs');
const ldap = require('ldapjs');
const nodemailer = require('nodemailer');
const app = express();
const PORT = process.env.PORT || 3443;

// Path to users file
const usersFilePath          = path.join(__dirname, 'users.json');
const deploymentsFilePath     = path.join(__dirname, 'deployments.json');
const auditLogsFilePath       = path.join(__dirname, 'audit-logs.json');
const idpConfigFilePath       = path.join(__dirname, 'idp-config.json');
const smtpConfigFilePath      = path.join(__dirname, 'smtp-config.json');
const lastDeploymentFilePath  = path.join(__dirname, 'last-deployment.json');

// Helper functions for SMTP configuration
function loadSmtpConfig() {
    try {
        if (fs.existsSync(smtpConfigFilePath)) {
            const data = fs.readFileSync(smtpConfigFilePath, 'utf8');
            return JSON.parse(data);
        }
    } catch (error) {
        console.error('Error loading SMTP config:', error);
    }
    return {
        enabled: false,
        host: process.env.SMTP_HOST || 'localhost',
        port: parseInt(process.env.SMTP_PORT) || 25,
        from: process.env.SMTP_USER || 'noreply@company.com',
        serverUrl: process.env.SERVER_URL || `https://localhost:${PORT}`
    };
}

function saveSmtpConfig(config) {
    try {
        fs.writeFileSync(smtpConfigFilePath, JSON.stringify(config, null, 2));
        // Reinitialize email transporter with new config
        initializeEmailTransporter();
        return true;
    } catch (error) {
        console.error('Error saving SMTP config:', error);
        return false;
    }
}

// Email configuration and transporter initialization
let emailTransporter = null;

function initializeEmailTransporter() {
    const config = loadSmtpConfig();
    
    if (!config.enabled || !config.host) {
        emailTransporter = null;
        console.log('Email service disabled');
        return;
    }

    try {
        const transportConfig = {
            host: config.host,
            port: config.port,
            secure: false, // use STARTTLS if available
            tls: {
                rejectUnauthorized: false
            },
            // No authentication required
            ignoreTLS: config.port === 25 // For port 25, don't try TLS
        };

        emailTransporter = nodemailer.createTransport(transportConfig);
        console.log(`Email service configured: ${config.host}:${config.port}`);
    } catch (error) {
        emailTransporter = null;
        console.error('Failed to configure email service:', error);
    }
}

// Initialize email transporter on startup
initializeEmailTransporter();

// Load SSL certificates
const sslOptions = {
    key: fs.readFileSync(path.join(__dirname, 'certs', 'server.key')),
    cert: fs.readFileSync(path.join(__dirname, 'certs', 'server.crt'))
};

// Create HTTPS server
const server = https.createServer(sslOptions, app);

// Create WebSocket server
const wss = new WebSocket.Server({ server });

// Middleware
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true }));

// Session middleware
app.use(session({
    secret: process.env.SESSION_SECRET || 'change-this-secret-before-production',
    resave: false,
    saveUninitialized: false,
    cookie: {
        secure: true, // HTTPS only
        httpOnly: true,
        maxAge: 24 * 60 * 60 * 1000 // 24 hours
    }
}));

// JSON parsing error handler
app.use((err, req, res, next) => {
    if (err instanceof SyntaxError && err.status === 400 && 'body' in err) {
        console.error('JSON parsing error:', err);
        return res.status(400).json({ error: 'Invalid JSON in request body', details: err.message });
    }
    next(err);
});

// Request logging middleware
app.use((req, res, next) => {
    console.log(`${req.method} ${req.path} - User: ${req.session.user ? req.session.user.username : 'anonymous'}`);
    next();
});

// Authentication middleware
function requireAuth(req, res, next) {
    if (req.session && req.session.user) {
        return next();
    }
    
    // For API requests, return 401
    if (req.path.startsWith('/api/')) {
        return res.status(401).json({ error: 'Authentication required' });
    }
    
    // For page requests, redirect to login
    res.redirect('/login.html');
}

// Admin middleware
function requireAdmin(req, res, next) {
    if (req.session && req.session.user && req.session.user.role === 'admin') {
        return next();
    }
    
    if (req.path.startsWith('/api/')) {
        return res.status(403).json({ error: 'Admin access required' });
    }
    
    res.status(403).send('Admin access required');
}

// Helper functions for user management
function loadUsers() {
    try {
        if (fs.existsSync(usersFilePath)) {
            const data = fs.readFileSync(usersFilePath, 'utf8');
            return JSON.parse(data);
        }
    } catch (error) {
        console.error('Error loading users:', error);
    }
    return { users: [] };
}

function saveUsers(usersData) {
    try {
        fs.writeFileSync(usersFilePath, JSON.stringify(usersData, null, 2));
        return true;
    } catch (error) {
        console.error('Error saving users:', error);
        return false;
    }
}

// Helper functions for Identity Provider (AD/LDAP) configuration
function loadIdpConfig() {
    try {
        if (fs.existsSync(idpConfigFilePath)) {
            const data = fs.readFileSync(idpConfigFilePath, 'utf8');
            return JSON.parse(data);
        }
    } catch (error) {
        console.error('Error loading IdP config:', error);
    }
    return {
        enabled: false,
        server: '',
        port: 389,
        useSsl: false,
        bindDN: '',
        bindPassword: '',
        baseDN: '',
        userSearchFilter: '(sAMAccountName={{username}})',
        displayNameAttr: 'displayName',
        emailAttr: 'mail',
        defaultRole: 'user'
    };
}

function saveIdpConfig(config) {
    try {
        fs.writeFileSync(idpConfigFilePath, JSON.stringify(config, null, 2));
        return true;
    } catch (error) {
        console.error('Error saving IdP config:', error);
        return false;
    }
}

// LDAP/AD helper: authenticate a user against AD
function authenticateWithAD(username, password) {
    return new Promise((resolve, reject) => {
        const config = loadIdpConfig();
        if (!config.enabled) {
            return reject(new Error('Identity Provider not enabled'));
        }

        const useSsl = config.useSsl || config.port === 636;
        const protocol = useSsl ? 'ldaps' : 'ldap';
        const url = `${protocol}://${config.server}:${config.port}`;

        const client = ldap.createClient({
            url: url,
            tlsOptions: { rejectUnauthorized: false },
            connectTimeout: 10000
        });

        client.on('error', (err) => {
            console.error('LDAP client error:', err);
            reject(new Error('Failed to connect to AD server'));
        });

        // First bind with service account to find the user
        client.bind(config.bindDN, config.bindPassword, (err) => {
            if (err) {
                client.unbind();
                return reject(new Error('Failed to bind to AD server'));
            }

            // Search for the user
            const searchFilter = config.userSearchFilter.replace('{{username}}', username);
            const displayNameAttr = config.displayNameAttr || 'displayName';
            const emailAttr = config.emailAttr || 'mail';
            const opts = {
                filter: searchFilter,
                scope: 'sub',
                attributes: ['dn', 'sAMAccountName', displayNameAttr, emailAttr]
            };

            client.search(config.baseDN, opts, (err, res) => {
                if (err) {
                    try { client.unbind(); } catch(e) {}
                    return reject(new Error('LDAP search failed'));
                }

                let userDN = null;
                let userData = null;

                res.on('searchEntry', (entry) => {
                    userDN = entry.pojo ? entry.pojo.objectName : (entry.objectName || entry.dn);
                    const attrs = {};
                    if (entry.attributes) {
                        entry.attributes.forEach(attr => {
                            attrs[attr.type] = attr.values && attr.values.length === 1 ? attr.values[0] : (attr.values || []);
                        });
                    }
                    userData = attrs;
                });

                res.on('error', (err) => {
                    try { client.unbind(); } catch(e) {}
                    reject(new Error('LDAP search error: ' + err.message));
                });

                res.on('end', (result) => {
                    if (!userDN) {
                        try { client.unbind(); } catch(e) {}
                        return reject(new Error('User not found in AD'));
                    }

                    // Now bind as the user to verify password
                    client.bind(userDN.toString(), password, (err) => {
                        try { client.unbind(); } catch(e) {}
                        if (err) {
                            return reject(new Error('Invalid AD password'));
                        }
                        resolve({
                            username: username,
                            displayName: userData ? (userData[displayNameAttr] || username) : username,
                            email: userData ? (userData[emailAttr] || '') : '',
                            source: 'ad'
                        });
                    });
                });
            });
        });
    });
}

// LDAP/AD helper: search users in AD
function searchADUsers(searchTerm) {
    return new Promise((resolve, reject) => {
        const config = loadIdpConfig();
        if (!config.enabled) {
            return reject(new Error('Identity Provider not enabled'));
        }

        const useSsl = config.useSsl || config.port === 636;
        const protocol = useSsl ? 'ldaps' : 'ldap';
        const url = `${protocol}://${config.server}:${config.port}`;

        const client = ldap.createClient({
            url: url,
            tlsOptions: { rejectUnauthorized: false },
            connectTimeout: 10000
        });

        client.on('error', (err) => {
            console.error('LDAP client error:', err);
            reject(new Error('Failed to connect to AD server'));
        });

        client.bind(config.bindDN, config.bindPassword, (err) => {
            if (err) {
                try { client.unbind(); } catch(e) {}
                return reject(new Error('Failed to bind to AD server: ' + err.message));
            }

            // Strip domain prefix (e.g. "DOMAIN\username" -> "username")
            let cleanTerm = searchTerm;
            if (cleanTerm.includes('\\')) {
                cleanTerm = cleanTerm.split('\\').pop();
            }
            if (cleanTerm.includes('/')) {
                cleanTerm = cleanTerm.split('/').pop();
            }

            // Use exact prefix match on sAMAccountName for speed, wildcard on displayName
            const searchFilter = `(&(objectClass=user)(objectCategory=person)(!(userAccountControl:1.2.840.113556.1.4.803:=2))(|(sAMAccountName=${cleanTerm})(sAMAccountName=${cleanTerm}*)(displayName=*${cleanTerm}*)(mail=${cleanTerm}*)))`;
            const displayNameAttr = config.displayNameAttr || 'displayName';
            const emailAttr = config.emailAttr || 'mail';
            const opts = {
                filter: searchFilter,
                scope: 'sub',
                attributes: ['sAMAccountName', displayNameAttr, emailAttr],
                sizeLimit: 20,
                timeLimit: 30
            };

            client.search(config.baseDN, opts, (err, res) => {
                if (err) {
                    try { client.unbind(); } catch(e) {}
                    return reject(new Error('LDAP search failed: ' + err.message));
                }

                const users = [];

                res.on('searchEntry', (entry) => {
                    const attrs = {};
                    if (entry.attributes) {
                        entry.attributes.forEach(attr => {
                            attrs[attr.type] = attr.values && attr.values.length === 1 ? attr.values[0] : (attr.values || []);
                        });
                    }
                    users.push({
                        username: attrs.sAMAccountName || '',
                        displayName: attrs[displayNameAttr] || attrs.sAMAccountName || '',
                        email: attrs[emailAttr] || ''
                    });
                });

                res.on('error', (err) => {
                    try { client.unbind(); } catch(e) {}
                    // If we got partial results before the error (e.g. time/size limit), return them
                    if (users.length > 0) {
                        console.log(`LDAP search returned ${users.length} partial results before error: ${err.message}`);
                        resolve(users);
                    } else {
                        reject(new Error('LDAP search error: ' + err.message));
                    }
                });

                res.on('end', () => {
                    try { client.unbind(); } catch(e) {}
                    resolve(users);
                });
            });
        });
    });
}

// Helper functions for deployment tracking
function loadDeployments() {
    try {
        if (fs.existsSync(deploymentsFilePath)) {
            const data = fs.readFileSync(deploymentsFilePath, 'utf8');
            return JSON.parse(data);
        }
    } catch (error) {
        console.error('Error loading deployments:', error);
    }
    return { deployments: [], statistics: { total: 0, dryRun: 0, production: 0, successful: 0, failed: 0 } };
}

function saveDeployment(deploymentData) {
    try {
        const data = loadDeployments();
        
        // Add new deployment
        data.deployments.unshift(deploymentData);
        
        // Clean up old deployments (older than 30 days)
        const thirtyDaysAgo = new Date();
        thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
        
        data.deployments = data.deployments.filter(deployment => {
            const deploymentDate = new Date(deployment.timestamp);
            return deploymentDate >= thirtyDaysAgo;
        });
        
        // Recalculate statistics from filtered deployments
        data.statistics = {
            total: data.deployments.length,
            dryRun: data.deployments.filter(d => d.isDryRun).length,
            production: data.deployments.filter(d => !d.isDryRun).length,
            successful: data.deployments.filter(d => d.success).length,
            failed: data.deployments.filter(d => !d.success).length
        };
        
        fs.writeFileSync(deploymentsFilePath, JSON.stringify(data, null, 2));
        console.log(`Deployment saved. Total deployments in last 30 days: ${data.deployments.length}`);
        return true;
    } catch (error) {
        console.error('Error saving deployment:', error);
        return false;
    }
}

// Helper functions for audit logging
function loadAuditLogs() {
    try {
        if (fs.existsSync(auditLogsFilePath)) {
            const data = fs.readFileSync(auditLogsFilePath, 'utf8');
            const parsed = JSON.parse(data);
            // Support both {logs:[]} object format and legacy [] array format
            if (Array.isArray(parsed)) return { logs: parsed };
            if (parsed && Array.isArray(parsed.logs)) return parsed;
        }
    } catch (error) {
        console.error('Error loading audit logs:', error);
    }
    return { logs: [] };
}

function saveAuditLog(action, details, username) {
    try {
        const data = loadAuditLogs();
        
        const logEntry = {
            id: Date.now(),
            timestamp: new Date().toISOString(),
            username: username,
            action: action,
            details: details
        };
        
        data.logs.unshift(logEntry);
        
        // Clean up old logs (older than 30 days)
        const thirtyDaysAgo = new Date();
        thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
        
        data.logs = data.logs.filter(log => {
            const logDate = new Date(log.timestamp);
            return logDate >= thirtyDaysAgo;
        });
        
        fs.writeFileSync(auditLogsFilePath, JSON.stringify(data, null, 2));
        console.log(`Audit log saved: ${action} by ${username}. Total logs in last 30 days: ${data.logs.length}`);
        return true;
    } catch (error) {
        console.error('Error saving audit log:', error);
        return false;
    }
}

// Helper function to send welcome email to newly imported user
async function sendWelcomeEmail(user) {
    if (!emailTransporter) {
        console.log('Email service not configured, skipping welcome email');
        return { success: false, message: 'Email service not configured' };
    }

    try {
        const smtpConfig = loadSmtpConfig();
        
        // Construct user email from username
        const userEmail = user.email || user.username.toLowerCase();
        
        // Get the server URL from config
        const serverUrl = smtpConfig.serverUrl || `https://localhost:${PORT}`;
        
        const mailOptions = {
            from: smtpConfig.from,
            to: userEmail,
            subject: 'Welcome to Nutanix Cluster Deployment Manager',
            html: `
                <!DOCTYPE html>
                <html>
                <head>
                    <meta charset="UTF-8">
                    <meta name="viewport" content="width=device-width, initial-scale=1.0">
                </head>
                <body style="margin: 0; padding: 0; background-color: #f4f4f4; font-family: Arial, sans-serif;">
                    <table width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color: #f4f4f4; padding: 20px 0;">
                        <tr>
                            <td align="center">
                                <table width="600" cellpadding="0" cellspacing="0" border="0" style="background-color: #ffffff; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 4px rgba(0,0,0,0.1);">
                                    <!-- Header -->
                                    <tr>
                                        <td bgcolor="#024da1" style="background-color: #024da1; padding: 40px 30px; text-align: center;">
                                            <h1 style="color: #ffffff; margin: 0; font-size: 28px; font-weight: 600;">Welcome Onboard!</h1>
                                            <p style="color: #ffffff; margin: 10px 0 0 0; font-size: 16px; font-weight: 500;">Nutanix Cluster Deployment Manager</p>
                                        </td>
                                    </tr>
                                    
                                    <!-- Content -->
                                    <tr>
                                        <td style="padding: 40px 30px;">
                                            <p style="color: #333333; font-size: 16px; line-height: 1.6; margin: 0 0 20px 0;">Dear <strong>${user.displayName || user.username}</strong>,</p>
                                            
                                            <p style="color: #333333; font-size: 16px; line-height: 1.6; margin: 0 0 20px 0;">
                                                We're excited to inform you that you have been granted access to the <strong>Nutanix Cluster Deployment Manager</strong> platform!
                                            </p>
                                            
                                            <h2 style="color: #024da1; font-size: 20px; margin: 30px 0 15px 0;">About the Platform</h2>
                                            <p style="color: #555555; font-size: 15px; line-height: 1.6; margin: 0 0 15px 0;">
                                                The Nutanix Cluster Deployment Manager is a powerful web-based tool designed to streamline and automate the deployment of Nutanix clusters in our infrastructure. This platform enables you to:
                                            </p>
                                            
                                            <ul style="color: #555555; font-size: 15px; line-height: 1.8; margin: 0 0 25px 0; padding-left: 25px;">
                                                <li>Deploy Nutanix clusters with customizable configurations</li>
                                                <li>Monitor deployment progress in real-time</li>
                                                <li>Manage deployment configurations and templates</li>
                                                <li>Track deployment history and statistics</li>
                                                <li>Perform dry-run tests before actual deployment</li>
                                            </ul>
                                            
                                            <h2 style="color: #024da1; font-size: 20px; margin: 30px 0 15px 0;">Your Account Details</h2>
                                            <table width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color: #f8f9fa; border: 1px solid #e1e4e8; border-radius: 6px; margin: 0 0 25px 0;">
                                                <tr>
                                                    <td style="padding: 20px;">
                                                        <table width="100%" cellpadding="8" cellspacing="0" border="0">
                                                            <tr>
                                                                <td style="color: #666666; font-size: 14px; width: 30%;"><strong>Username:</strong></td>
                                                                <td style="color: #333333; font-size: 14px;">${user.username}</td>
                                                            </tr>
                                                            <tr>
                                                                <td style="color: #666666; font-size: 14px;"><strong>Access Level:</strong></td>
                                                                <td style="color: #333333; font-size: 14px; text-transform: capitalize;">${user.role}</td>
                                                            </tr>
                                                            <tr>
                                                                <td style="color: #666666; font-size: 14px;"><strong>Authentication:</strong></td>
                                                                <td style="color: #333333; font-size: 14px;">Active Directory (Use your domain credentials)</td>
                                                            </tr>
                                                        </table>
                                                    </td>
                                                </tr>
                                            </table>
                                            
                                            <h2 style="color: #024da1; font-size: 20px; margin: 30px 0 15px 0;">Get Started</h2>
                                            <p style="color: #555555; font-size: 15px; line-height: 1.6; margin: 0 0 10px 0;">
                                                Click the button below to access the portal and start deploying Nutanix clusters.
                                            </p>
                                            <p style="color: #555555; font-size: 15px; line-height: 1.6; margin: 0 0 20px 0;">
                                                <strong>For the best experience, please use Google Chrome browser.</strong>
                                            </p>
                                            
                                            <div style="text-align: center; margin: 30px 0;">
                                                <a href="${serverUrl}" style="display: inline-block; background-color: #0066cc; color: #ffffff; text-decoration: none; padding: 16px 45px; border-radius: 6px; font-size: 17px; font-weight: 600; box-shadow: 0 4px 10px rgba(0, 102, 204, 0.4);">
                                                    Access Portal
                                                </a>
                                            </div>
                                            
                                            <p style="color: #777777; font-size: 13px; line-height: 1.5; margin: 20px 0 0 0; text-align: center;">
                                                Or copy and paste this link into your browser:<br>
                                                <a href="${serverUrl}" style="color: #024da1; text-decoration: none; word-break: break-all;">${serverUrl}</a>
                                            </p>
                                            
                                            <div style="margin: 35px 0 0 0; padding: 20px; background-color: #fff8dc; border-left: 4px solid #ffa500; border-radius: 4px;">
                                                <p style="color: #856404; font-size: 14px; line-height: 1.5; margin: 0;">
                                                    <strong>💡 Quick Tip:</strong> Make sure to use your Active Directory credentials (username and password) to log in to the portal.
                                                </p>
                                            </div>
                                        </td>
                                    </tr>
                                    
                                    <!-- Footer -->
                                    <tr>
                                        <td style="background-color: #f8f9fa; padding: 30px; border-top: 1px solid #e1e4e8;">
                                            <p style="color: #333333; font-size: 15px; line-height: 1.6; margin: 0 0 15px 0;">
                                                If you have any questions or need assistance, please don't hesitate to contact us.
                                            </p>
                                            <p style="color: #333333; font-size: 15px; line-height: 1.6; margin: 0 0 5px 0; font-weight: 600;">
                                                Best regards,
                                            </p>
                                            <p style="color: #024da1; font-size: 15px; line-height: 1.6; margin: 0; font-weight: 600;">
                                                Nutanix ZTI Automation Team
                                            </p>
                                            
                                            <hr style="border: none; border-top: 1px solid #e1e4e8; margin: 25px 0 15px 0;">
                                            
                                            <p style="color: #999999; font-size: 12px; line-height: 1.5; margin: 0; text-align: center;">
                                                This is an automated message. Please do not reply to this email.<br>
                                                © ${new Date().getFullYear()} Nutanix ZTI Deployment Tool. All rights reserved.
                                            </p>
                                        </td>
                                    </tr>
                                </table>
                            </td>
                        </tr>
                    </table>
                </body>
                </html>
            `
        };

        const info = await emailTransporter.sendMail(mailOptions);
        console.log('Welcome email sent to:', userEmail, '- Message ID:', info.messageId);
        return { success: true, messageId: info.messageId, email: userEmail };
    } catch (error) {
        console.error('Failed to send welcome email:', error);
        return { success: false, error: error.message };
    }
}

// Path to configs directory and deployment script (Nutanix-ZTI folder, sibling of this app)
const configsPath = path.join(__dirname, '..', 'Nutanix-ZTI', 'Configs');
const deployScriptPath = path.join(__dirname, '..', 'Nutanix-ZTI', 'Start-Pipeline.ps1');

// Store active deployment process
let activeDeployment = null;

// Last completed/failed deployment — persisted to disk so it survives restarts.
// Enables re-login users to see the final state and full log after a run finishes.
let lastDeployment = null;
try {
    if (fs.existsSync(lastDeploymentFilePath)) {
        lastDeployment = JSON.parse(fs.readFileSync(lastDeploymentFilePath, 'utf8'));
        console.log(`Loaded last deployment state: ${lastDeployment.clusterName} (${lastDeployment.status})`);
    }
} catch (_) {}

// WebSocket connection handling
wss.on('connection', (ws) => {
    console.log('WebSocket client connected');

    if (activeDeployment) {
        // Deployment in progress — send live state
        ws.send(JSON.stringify({
            type:           'deployment_state',
            status:         'running',
            filename:       activeDeployment.filename,
            clusterName:    activeDeployment.clusterName,
            isDryRun:       activeDeployment.isDryRun,
            startAtStep:    activeDeployment.startAtStep,
            stepStatuses:   activeDeployment.stepStatuses,
            currentStepNum: activeDeployment.currentStepNum,
            logBuffer:      activeDeployment.logBuffer
        }));
    } else if (lastDeployment) {
        // No active run — send last completed/failed deployment so user can review it
        ws.send(JSON.stringify(Object.assign({ type: 'deployment_state' }, lastDeployment)));
    }

    ws.on('close', () => {
        console.log('WebSocket client disconnected');
    });
});

// Broadcast to all connected WebSocket clients
// Log messages are buffered in activeDeployment.logBuffer so new clients get full history
function broadcast(data) {
    if (activeDeployment && data.type === 'log') {
        if (activeDeployment.logBuffer.length < 5000) {
            activeDeployment.logBuffer.push({ message: data.message, level: data.level });
        }
    }
    wss.clients.forEach((client) => {
        if (client.readyState === WebSocket.OPEN) {
            client.send(JSON.stringify(data));
        }
    });
}

// Public routes (no authentication required)
app.get('/login.html', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'login.html'));
});

// Serve static files for login page only
app.use('/styles.css', express.static(path.join(__dirname, 'public', 'styles.css')));
app.use('/images',     express.static(path.join(__dirname, 'public', 'images')));

// Public branding endpoint — reads .env on every request so changes take effect without restart
app.get('/api/branding', (req, res) => {
    let companyName = process.env.COMPANY_NAME || 'Your Company Name';
    try {
        const envFile = path.join(__dirname, '.env');
        if (fs.existsSync(envFile)) {
            const parsed = require('dotenv').parse(fs.readFileSync(envFile));
            if (parsed.COMPANY_NAME) companyName = parsed.COMPANY_NAME;
        }
    } catch (_) { /* fall back to process.env value */ }
    res.json({ companyName });
});

// Authentication routes
app.post('/api/login', async (req, res) => {
    try {
        let { username, password } = req.body;
        
        if (!username || !password) {
            return res.status(400).json({ error: 'Username and password are required' });
        }
        
        // Strip domain prefix (e.g. "DOMAIN\username" or "DOMAIN/username" -> "username")
        let cleanUsername = username;
        if (cleanUsername.includes('\\')) {
            cleanUsername = cleanUsername.split('\\').pop();
        }
        if (cleanUsername.includes('/')) {
            cleanUsername = cleanUsername.split('/').pop();
        }
        
        const usersData = loadUsers();
        
        // Case-insensitive user lookup
        const user = usersData.users.find(u => u.username.toLowerCase() === cleanUsername.toLowerCase());
        
        // Try local authentication first
        if (user && user.source !== 'ad') {
            const passwordMatch = await bcrypt.compare(password, user.password);
            
            if (passwordMatch) {
                req.session.user = {
                    id: user.id,
                    username: user.username,
                    role: user.role
                };
                saveAuditLog('login', { success: true, source: 'local' }, user.username);
                console.log('User logged in (local):', user.username);
                return res.json({ success: true, user: { username: user.username, role: user.role } });
            }
        }

        // Try AD authentication if IdP is enabled
        const idpConfig = loadIdpConfig();
        if (idpConfig.enabled) {
            try {
                const adUser = await authenticateWithAD(cleanUsername, password);
                
                // Check if AD user exists locally (imported) - case-insensitive
                let localUser = usersData.users.find(u => u.username.toLowerCase() === cleanUsername.toLowerCase() && u.source === 'ad');
                
                if (localUser) {
                    req.session.user = {
                        id: localUser.id,
                        username: localUser.username,
                        role: localUser.role
                    };
                    saveAuditLog('login', { success: true, source: 'ad' }, localUser.username);
                    console.log('User logged in (AD):', localUser.username);
                    return res.json({ success: true, user: { username: localUser.username, role: localUser.role } });
                } else {
                    // AD user not imported yet
                    saveAuditLog('login_denied', { reason: 'AD user not imported', source: 'ad' }, cleanUsername);
                    return res.status(401).json({ error: 'Your AD account is valid but has not been added to this application. Contact an administrator.' });
                }
            } catch (adError) {
                console.log('AD authentication failed for', cleanUsername, ':', adError.message);
            }
        }

        // If local user exists but password didn't match
        if (user && user.source !== 'ad') {
            saveAuditLog('login', { success: false, source: 'local' }, cleanUsername);
            return res.status(401).json({ error: 'Invalid username or password' });
        }

        // No match anywhere
        return res.status(401).json({ error: 'Invalid username or password' });
    } catch (error) {
        console.error('Login error:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

app.post('/api/logout', (req, res) => {
    const username = req.session?.user?.username || 'unknown';
    
    req.session.destroy((err) => {
        if (err) {
            return res.status(500).json({ error: 'Failed to logout' });
        }
        
        // Log audit event
        saveAuditLog('logout', { success: true }, username);
        
        res.json({ success: true });
    });
});

// Get current user info
app.get('/api/current-user', requireAuth, (req, res) => {
    res.json({
        username: req.session.user.username,
        role: req.session.user.role
    });
});

// User management routes (admin only)
app.get('/api/users', requireAuth, requireAdmin, (req, res) => {
    try {
        const usersData = loadUsers();
        // Don't send passwords to client
        const users = usersData.users.map(({ password, ...user }) => user);
        res.json({ users });
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

app.post('/api/users', requireAuth, requireAdmin, async (req, res) => {
    try {
        const { username, password, role } = req.body;
        
        if (!username || !password) {
            return res.status(400).json({ error: 'Username and password are required' });
        }
        
        if (password.length < 6) {
            return res.status(400).json({ error: 'Password must be at least 6 characters' });
        }
        
        const usersData = loadUsers();
        
        // Check if username already exists
       if (usersData.users.find(u => u.username === username)) {
            return res.status(400).json({ error: 'Username already exists' });
        }
        
        // Hash password
        const hashedPassword = await bcrypt.hash(password, 10);
        
        // Create new user
        const newUser = {
            id: Math.max(0, ...usersData.users.map(u => u.id)) + 1,
            username,
            password: hashedPassword,
            role: role || 'user',
            createdAt: new Date().toISOString()
        };
        
        usersData.users.push(newUser);
        
        if (saveUsers(usersData)) {
            // Log audit event
            saveAuditLog('user_created', {
                targetUser: username,
                role: role || 'user'
            }, req.session.user.username);
            
            const { password: _, ...userWithoutPassword } = newUser;
            res.json({ success: true, user: userWithoutPassword });
        } else {
            res.status(500).json({ error: 'Failed to save user' });
        }
    } catch (error) {
        console.error('Error creating user:', error);
        res.status(500).json({ error: error.message });
    }
});

app.delete('/api/users/:id', requireAuth, requireAdmin, (req, res) => {
    try {
        const userId = parseInt(req.params.id);
        const usersData = loadUsers();
        
        const user = usersData.users.find(u => u.id === userId);
        
        if (!user) {
            return res.status(404).json({ error: 'User not found' });
        }
        
        // Prevent deleting admin user
        if (user.username === 'admin') {
            return res.status(403).json({ error: 'Cannot delete admin user' });
        }
        
        usersData.users = usersData.users.filter(u => u.id !== userId);
        
        if (saveUsers(usersData)) {
            // Log audit event
            saveAuditLog('user_deleted', {
                targetUser: user.username,
                userId: userId
            }, req.session.user.username);
            
            res.json({ success: true });
        } else {
            res.status(500).json({ error: 'Failed to delete user' });
        }
    } catch (error) {
        console.error('Error deleting user:', error);
        res.status(500).json({ error: error.message });
    }
});

// Change password (admin only, local users only)
app.put('/api/users/:id/password', requireAuth, requireAdmin, async (req, res) => {
    try {
        const userId = parseInt(req.params.id);
        const { newPassword } = req.body;
        
        if (!newPassword || newPassword.length < 6) {
            return res.status(400).json({ error: 'Password must be at least 6 characters' });
        }
        
        const usersData = loadUsers();
        const user = usersData.users.find(u => u.id === userId);
        
        if (!user) {
            return res.status(404).json({ error: 'User not found' });
        }
        
        if (user.source === 'ad') {
            return res.status(400).json({ error: 'Cannot change password for AD users. Passwords are managed in Active Directory.' });
        }
        
        const hashedPassword = await bcrypt.hash(newPassword, 10);
        user.password = hashedPassword;
        
        if (saveUsers(usersData)) {
            saveAuditLog('password_changed', { targetUser: user.username }, req.session.user.username);
            res.json({ success: true, message: `Password changed for ${user.username}` });
        } else {
            res.status(500).json({ error: 'Failed to save password' });
        }
    } catch (error) {
        console.error('Error changing password:', error);
        res.status(500).json({ error: error.message });
    }
});

// Protected routes (require authentication)
app.get('/', requireAuth, (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.get('/admin.html', requireAuth, requireAdmin, (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'admin.html'));
});

// ========== Identity Provider (AD/LDAP) API Routes ==========

// Get IdP configuration (admin only)
app.get('/api/idp/config', requireAuth, requireAdmin, (req, res) => {
    try {
        const config = loadIdpConfig();
        // Don't send bind password to client
        const safeConfig = { ...config, bindPassword: config.bindPassword ? '********' : '' };
        res.json(safeConfig);
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

// Save IdP configuration (admin only)
app.post('/api/idp/config', requireAuth, requireAdmin, (req, res) => {
    try {
        const newConfig = req.body;
        const existingConfig = loadIdpConfig();
        
        // Ensure display/email attrs have defaults
        newConfig.displayNameAttr = newConfig.displayNameAttr || 'displayName';
        newConfig.emailAttr = newConfig.emailAttr || 'mail';
        
        // If password is masked, keep the existing one
        if (newConfig.bindPassword === '********') {
            newConfig.bindPassword = existingConfig.bindPassword;
        }
        
        if (saveIdpConfig(newConfig)) {
            saveAuditLog('idp_config_updated', { enabled: newConfig.enabled, server: newConfig.server }, req.session.user.username);
            res.json({ success: true, message: 'Identity Provider configuration saved' });
        } else {
            res.status(500).json({ error: 'Failed to save configuration' });
        }
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

// Test IdP connection (admin only)
app.post('/api/idp/test', requireAuth, requireAdmin, (req, res) => {
    const config = req.body;
    const existingConfig = loadIdpConfig();
    let responded = false;
    
    function sendResponse(status, body) {
        if (!responded) {
            responded = true;
            res.status(status).json(body);
        }
    }
    
    // If password is masked, use existing
    if (config.bindPassword === '********') {
        config.bindPassword = existingConfig.bindPassword;
    }
    
    // Auto-detect SSL for port 636
    const useSsl = config.useSsl || config.port === 636;
    const protocol = useSsl ? 'ldaps' : 'ldap';
    const url = `${protocol}://${config.server}:${config.port}`;

    console.log('Testing LDAP connection to:', url, 'with bindDN:', config.bindDN);

    const client = ldap.createClient({
        url: url,
        tlsOptions: { rejectUnauthorized: false },
        connectTimeout: 10000
    });

    client.on('error', (err) => {
        console.error('LDAP test connection error:', err.message);
        sendResponse(500, { error: 'Connection failed: ' + err.message });
    });

    client.on('connectError', (err) => {
        console.error('LDAP test connectError:', err.message);
        sendResponse(500, { error: 'Connection failed: ' + err.message });
    });

    client.bind(config.bindDN, config.bindPassword, (err) => {
        if (err) {
            console.error('LDAP test bind error:', err.message);
            try { client.unbind(); } catch(e) {}
            return sendResponse(400, { error: 'Bind failed: ' + err.message });
        }
        
        // Try a basic search to verify baseDN
        client.search(config.baseDN, { scope: 'base', filter: '(objectClass=*)' }, (err, searchRes) => {
            if (err) {
                try { client.unbind(); } catch(e) {}
                return sendResponse(400, { error: 'Base DN search failed: ' + err.message });
            }
            
            searchRes.on('end', () => {
                try { client.unbind(); } catch(e) {}
                saveAuditLog('idp_test_connection', { success: true, server: config.server }, req.session.user.username);
                sendResponse(200, { success: true, message: 'Connection successful! AD server is reachable.' });
            });
            
            searchRes.on('error', (err) => {
                try { client.unbind(); } catch(e) {}
                sendResponse(400, { error: 'Search error: ' + err.message });
            });
        });
    });
});

// Search AD users (admin only)
app.get('/api/idp/search-users', requireAuth, requireAdmin, async (req, res) => {
    try {
        const searchTerm = req.query.q;
        if (!searchTerm || searchTerm.length < 2) {
            return res.status(400).json({ error: 'Search term must be at least 2 characters' });
        }
        
        const users = await searchADUsers(searchTerm);
        
        // Mark which users are already imported
        const localUsers = loadUsers();
        const importedUsernames = localUsers.users.filter(u => u.source === 'ad').map(u => u.username);
        
        const results = users.map(u => ({
            ...u,
            imported: importedUsernames.includes(u.username)
        }));
        
        res.json({ users: results });
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

// Import AD user (admin only)
app.post('/api/idp/import-user', requireAuth, requireAdmin, async (req, res) => {
    try {
        const { username, displayName, email, role } = req.body;
        
        if (!username) {
            return res.status(400).json({ error: 'Username is required' });
        }
        
        const usersData = loadUsers();
        
        // Check if user already exists
        if (usersData.users.find(u => u.username === username)) {
            return res.status(400).json({ error: 'User already exists in the application' });
        }
        
        // Create AD user entry (no local password - authenticates via AD)
        const newUser = {
            id: Math.max(0, ...usersData.users.map(u => u.id)) + 1,
            username: username,
            password: '',
            role: role || loadIdpConfig().defaultRole || 'user',
            source: 'ad',
            displayName: displayName || username,
            email: email || username.toLowerCase(),
            createdAt: new Date().toISOString()
        };
        
        usersData.users.push(newUser);
        
        if (saveUsers(usersData)) {
            saveAuditLog('ad_user_imported', { targetUser: username, displayName, role: newUser.role }, req.session.user.username);
            
            // Send welcome email to the imported user
            const emailResult = await sendWelcomeEmail(newUser);
            
            const { password: _, ...userWithoutPassword } = newUser;
            res.json({ 
                success: true, 
                user: userWithoutPassword,
                emailSent: emailResult.success,
                emailDetails: emailResult.success ? { sentTo: emailResult.email } : { error: emailResult.message || emailResult.error }
            });
        } else {
            res.status(500).json({ error: 'Failed to save user' });
        }
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

// ========== End Identity Provider Routes ==========

// ========== SMTP Configuration API Routes ==========

// Get SMTP configuration (admin only)
app.get('/api/smtp/config', requireAuth, requireAdmin, (req, res) => {
    try {
        const config = loadSmtpConfig();
        res.json(config);
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

// Save SMTP configuration (admin only)
app.post('/api/smtp/config', requireAuth, requireAdmin, (req, res) => {
    try {
        const { host, port, from, serverUrl, enabled } = req.body;
        
        if (enabled && (!host || !port || !from)) {
            return res.status(400).json({ error: 'Host, port, and sender email are required when SMTP is enabled' });
        }
        
        const config = {
            enabled: enabled || false,
            host: host || 'localhost',
            port: parseInt(port) || 25,
            from: from || 'noreply@company.com',
            serverUrl: serverUrl || `https://localhost:${PORT}`
        };
        
        if (saveSmtpConfig(config)) {
            saveAuditLog('smtp_config_updated', { host: config.host, port: config.port, enabled: config.enabled }, req.session.user.username);
            res.json({ success: true, config });
        } else {
            res.status(500).json({ error: 'Failed to save SMTP configuration' });
        }
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

// Test SMTP connection (admin only)
app.post('/api/smtp/test', requireAuth, requireAdmin, async (req, res) => {
    try {
        const { testEmail } = req.body;
        
        if (!testEmail) {
            return res.status(400).json({ error: 'Test email address is required' });
        }
        
        if (!emailTransporter) {
            return res.status(400).json({ error: 'SMTP is not configured. Please save SMTP configuration first.' });
        }
        
        const smtpConfig = loadSmtpConfig();
        
        const mailOptions = {
            from: smtpConfig.from,
            to: testEmail,
            subject: 'SMTP Test - Nutanix Cluster Deployment Manager',
            html: `
                <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
                    <h2 style="color: #024da1;">SMTP Test Email</h2>
                    <p>This is a test email from the Nutanix Cluster Deployment Manager.</p>
                    <p>If you received this email, your SMTP configuration is working correctly.</p>
                    <hr style="border: 1px solid #ddd; margin: 20px 0;">
                    <p style="color: #666; font-size: 0.9rem;"><strong>Test Details:</strong></p>
                    <ul style="color: #666; font-size: 0.9rem;">
                        <li>SMTP Server: ${smtpConfig.host}:${smtpConfig.port}</li>
                        <li>Sender: ${smtpConfig.from}</li>
                        <li>Recipient: ${testEmail}</li>
                        <li>Time: ${new Date().toISOString()}</li>
                    </ul>
                    <p style="color: #666; font-size: 12px; margin-top: 20px;">This is an automated test message.</p>
                </div>
            `
        };
        
        const info = await emailTransporter.sendMail(mailOptions);
        saveAuditLog('smtp_test_sent', { testEmail, messageId: info.messageId }, req.session.user.username);
        
        res.json({ 
            success: true, 
            message: 'Test email sent successfully',
            messageId: info.messageId,
            recipient: testEmail
        });
    } catch (error) {
        console.error('SMTP test failed:', error);
        saveAuditLog('smtp_test_failed', { testEmail: req.body.testEmail, error: error.message }, req.session.user.username);
        res.status(500).json({ 
            error: 'Failed to send test email',
            details: error.message 
        });
    }
});

// ========== End SMTP Configuration Routes ==========

// Serve static files (protected)
app.use(requireAuth, express.static(path.join(__dirname, 'public')));

// API: List available configuration files
app.get('/api/configs', requireAuth, (req, res) => {
    try {
        if (!fs.existsSync(configsPath)) {
            return res.json({ files: [] });
        }
        
        const files = fs.readdirSync(configsPath)
            .filter(file => file.endsWith('.json'))
            .map(file => ({
                name: file,
                path: path.join(configsPath, file)
            }));
        
        res.json({ files });
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

// API: Load a specific configuration file
app.get('/api/config/:filename', requireAuth, (req, res) => {
    try {
        const filename = req.params.filename;
        const filePath = path.join(configsPath, filename);
        
        if (!fs.existsSync(filePath)) {
            return res.status(404).json({ error: 'Configuration file not found' });
        }
        
        const config = JSON.parse(fs.readFileSync(filePath, 'utf8'));
        
        // Log audit event
        saveAuditLog('config_loaded', {
            filename: filename,
            clusterName: config.cluster?.name || 'Unknown'
        }, req.session.user.username);
        
        res.json(config);
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

// API: Save a configuration file
app.post('/api/config/:filename', requireAuth, (req, res) => {
    try {
        console.log('Received save request for:', req.params.filename);
        console.log('Body type:', typeof req.body);
        console.log('Body keys:', Object.keys(req.body || {}));
        
        const filename = req.params.filename;
        const filePath = path.join(configsPath, filename);
        
        // Validate request body
        if (!req.body || typeof req.body !== 'object') {
            console.error('Invalid request body:', req.body);
            return res.status(400).json({ error: 'Invalid configuration data' });
        }
        
        // Ensure configs directory exists
        if (!fs.existsSync(configsPath)) {
            console.log('Creating configs directory:', configsPath);
            fs.mkdirSync(configsPath, { recursive: true });
        }
        
        // Convert config to JSON string
        const jsonString = JSON.stringify(req.body, null, 2);
        console.log('Saving configuration to:', filePath);
        console.log('Configuration length:', jsonString.length);
        
        fs.writeFileSync(filePath, jsonString);
        console.log('Configuration saved successfully');
        
        // Log audit event
        saveAuditLog('config_saved', {
            filename: filename,
            clusterName: req.body.cluster?.name || 'Unknown'
        }, req.session.user.username);
        
        res.json({ success: true, message: 'Configuration saved successfully' });
    } catch (error) {
        console.error('Error saving configuration:', error);
        res.status(500).json({ error: error.message, stack: error.stack });
    }
});

// API: Start deployment
// Abort the active deployment — kills the PowerShell process tree
app.post('/api/abort', requireAuth, (req, res) => {
    if (!activeDeployment || !activeDeployment.process) {
        return res.status(400).json({ error: 'No active deployment to abort' });
    }
    const clusterName = activeDeployment.clusterName;
    const username    = req.session.user.username;
    try {
        // Kill the entire process tree so child scripts are also terminated
        spawn('taskkill', ['/PID', String(activeDeployment.process.pid), '/T', '/F']);
    } catch (_) {}
    try { activeDeployment.process.kill('SIGTERM'); } catch (_) {}

    saveAuditLog('deployment_aborted', { clusterName }, username);

    broadcast({
        type:      'deployment_aborted',
        message:   'Deployment Force Aborted',
        timestamp: new Date().toISOString()
    });

    // Persist aborted state for re-login replay
    lastDeployment = {
        status:         'aborted',
        filename:       activeDeployment.filename,
        clusterName:    activeDeployment.clusterName,
        isDryRun:       activeDeployment.isDryRun,
        startAtStep:    activeDeployment.startAtStep,
        stepStatuses:   activeDeployment.stepStatuses,
        currentStepNum: activeDeployment.currentStepNum,
        logBuffer:      activeDeployment.logBuffer,
        startTime:      activeDeployment.startTime.toISOString(),
        endTime:        new Date().toISOString(),
        exitCode:       -1
    };
    fs.writeFile(lastDeploymentFilePath, JSON.stringify(lastDeployment), () => {});

    activeDeployment = null;
    res.json({ success: true, message: 'Deployment Force Aborted' });
});

app.post('/api/deploy', requireAuth, (req, res) => {
    try {
        if (activeDeployment) {
            return res.status(400).json({ error: 'A deployment is already in progress' });
        }
        
        const { config, filename, configPath, isDryRun, startAtStep, skipSteps, skipPreCheck } = req.body;

        // Resolve config file path — either use an existing file or save a new one
        let configFilePath;
        let actualFilename;

        if (configPath) {
            // Use existing config file directly — no date-stamped copy
            configFilePath = path.join(configsPath, configPath);
            if (!fs.existsSync(configFilePath)) {
                return res.status(400).json({ error: `Config file not found: ${configPath}` });
            }
            actualFilename = path.basename(configFilePath);
            console.log(`Using existing config: ${configFilePath}`);
        } else if (config && filename) {
            // Save new config
            configFilePath = path.join(configsPath, filename);
            if (!fs.existsSync(configsPath)) {
                fs.mkdirSync(configsPath, { recursive: true });
            }
            fs.writeFileSync(configFilePath, JSON.stringify(config, null, 2));
            actualFilename = filename;
            console.log(`Saved new config: ${configFilePath}`);
        } else {
            return res.status(400).json({ error: 'Either configPath or config+filename is required' });
        }

        // Build PowerShell arguments
        const psArgs = [
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', deployScriptPath,
            '-ConfigFile', configFilePath
        ];

        if (isDryRun) {
            psArgs.push('-DryRun');
            console.log(`DRY RUN: ${configFilePath}`);
        }

        const startStep = parseInt(startAtStep) || 1;
        if (startStep > 1) {
            psArgs.push('-StartAtStep');
            psArgs.push(String(startStep));
            console.log(`Starting at Step ${startStep}`);
        }

        const skipStepNums = Array.isArray(skipSteps) ? skipSteps.map(Number).filter(n => n > 0) : [];
        if (skipStepNums.length > 0) {
            psArgs.push('-SkipSteps');
            psArgs.push(skipStepNums.join(','));
            console.log(`Skipping steps: ${skipStepNums.join(', ')}`);
        }

        if (skipPreCheck) {
            psArgs.push('-SkipPreCheck');
            console.log('Pre-flight checks skipped by user request');
        }

        // Read notify fields from the saved config (To/CC for deployment result email)
        let notifyTo = '';
        let notifyCc = '';
        try {
            const savedCfg = configPath
                ? JSON.parse(fs.readFileSync(configFilePath, 'utf8'))
                : config;
            if (savedCfg && savedCfg.notify) {
                notifyTo = (savedCfg.notify.to  || '').trim();
                notifyCc = (savedCfg.notify.cc  || '').trim();
            }
        } catch (e) {
            console.log('Could not read notify fields from config:', e.message);
        }

        if (notifyTo) {
            psArgs.push('-TriggeredBy');
            psArgs.push(notifyTo);
            console.log(`Notify To: ${notifyTo}`);
        } else {
            console.log('No notify.to in config — pipeline result email will be skipped');
        }
        if (notifyCc) {
            psArgs.push('-Cc');
            psArgs.push(notifyCc);
        }

        // Start PowerShell deployment process
        // Set TERM + DOTNET outputEncoding so pwsh emits true ANSI colour codes and UTF-8
        const psProcess = spawn('pwsh.exe', psArgs, {
            cwd: path.dirname(deployScriptPath),
            env: Object.assign({}, process.env, {
                TERM: 'xterm-256color',
                DOTNET_SYSTEM_CONSOLE_ALLOW_ANSI_COLOR_REDIRECTION: '1',
                DOTNET_SYSTEM_GLOBALIZATION_INVARIANT: '0',
                PYTHONIOENCODING: 'utf-8'
            })
        });
        psProcess.stdout.setEncoding('utf8');
        psProcess.stderr.setEncoding('utf8');

        const username = req.session.user.username;
        // Read clusterName from existing file if using configPath
        let clusterName = 'Unknown';
        try {
            const cfgData = JSON.parse(fs.readFileSync(configFilePath, 'utf8'));
            clusterName = cfgData.clusterName || cfgData.cluster?.name || 'Unknown';
        } catch (_) {}

        activeDeployment = {
            process:        psProcess,
            filename:       actualFilename,
            configFilePath: configFilePath,
            startTime:      new Date(),
            isDryRun:       isDryRun || false,
            startAtStep:    startStep,
            skipSteps:      skipStepNums,
            username:       username,
            clusterName:    clusterName,
            currentStepNum: 0,
            linesSinceStepHeader: 999,
            stepStatuses:   {},
            logBuffer:      []
        };
        
        // Log audit event
        saveAuditLog('deployment_started', { 
            filename: actualFilename, 
            isDryRun: isDryRun || false,
            clusterName: clusterName
        }, username);
        
        // Send initial status
        broadcast({
            type: 'deployment_started',
            filename: actualFilename,
            timestamp: new Date().toISOString()
        });
        
        // Handle process output
        psProcess.stdout.on('data', (data) => {
            const output = data.toString();
            console.log('STDOUT:', output);
            
            // Broadcast with raw ANSI — the client renders colours via ansiToHtml()
            broadcast({
                type: 'log',
                level: 'raw',
                message: output,
                timestamp: new Date().toISOString()
            });
            
            // Parse output for step progress (strips ANSI internally)
            parseDeploymentOutput(output);
        });
        
        psProcess.stderr.on('data', (data) => {
            const output = data.toString();
            console.error('STDERR:', output);
            
            broadcast({
                type: 'log',
                level: 'raw',
                message: `\x1b[31m${output}\x1b[0m`,
                timestamp: new Date().toISOString()
            });
        });
        
        psProcess.on('close', (code) => {
            // Guard: if activeDeployment was already cleared by /api/abort, skip — abort handler
            // already persisted state and broadcast deployment_aborted.
            if (!activeDeployment) return;

            console.log(`Deployment process exited with code ${code}`);
            
            const success = code === 0;
            const endTime = new Date();
            const duration = Math.round((endTime - activeDeployment.startTime) / 1000); // seconds
            
            // Save deployment record
            saveDeployment({
                id: Date.now(),
                timestamp: activeDeployment.startTime.toISOString(),
                endTime: endTime.toISOString(),
                duration: duration,
                filename: activeDeployment.filename,
                clusterName: activeDeployment.clusterName,
                isDryRun: activeDeployment.isDryRun,
                success: success,
                exitCode: code,
                username: activeDeployment.username
            });
            
            // Log audit event
            saveAuditLog('deployment_completed', {
                filename: activeDeployment.filename,
                clusterName: activeDeployment.clusterName,
                isDryRun: activeDeployment.isDryRun,
                success: success,
                duration: duration
            }, activeDeployment.username);
            
            broadcast({
                type: 'deployment_completed',
                exitCode: code,
                success: success,
                timestamp: new Date().toISOString()
            });

            // Persist final state so re-login users can review it
            lastDeployment = {
                status:         success ? 'completed' : 'failed',
                filename:       activeDeployment.filename,
                clusterName:    activeDeployment.clusterName,
                isDryRun:       activeDeployment.isDryRun,
                startAtStep:    activeDeployment.startAtStep,
                stepStatuses:   activeDeployment.stepStatuses,
                currentStepNum: activeDeployment.currentStepNum,
                logBuffer:      activeDeployment.logBuffer,
                startTime:      activeDeployment.startTime.toISOString(),
                endTime:        endTime.toISOString(),
                duration:       duration,
                exitCode:       code
            };
            fs.writeFile(lastDeploymentFilePath, JSON.stringify(lastDeployment), () => {});

            activeDeployment = null;
        });
        
        psProcess.on('error', (error) => {
            console.error('Failed to start deployment:', error);
            
            broadcast({
                type: 'deployment_error',
                error: error.message,
                timestamp: new Date().toISOString()
            });

            // Persist error state
            if (activeDeployment) {
                lastDeployment = {
                    status:         'failed',
                    filename:       activeDeployment.filename,
                    clusterName:    activeDeployment.clusterName,
                    isDryRun:       activeDeployment.isDryRun,
                    startAtStep:    activeDeployment.startAtStep,
                    stepStatuses:   activeDeployment.stepStatuses,
                    currentStepNum: activeDeployment.currentStepNum,
                    logBuffer:      activeDeployment.logBuffer,
                    startTime:      activeDeployment.startTime.toISOString(),
                    endTime:        new Date().toISOString(),
                    exitCode:       -1
                };
                fs.writeFile(lastDeploymentFilePath, JSON.stringify(lastDeployment), () => {});
            }

            activeDeployment = null;
        });
        
        res.json({ 
            success: true, 
            message: 'Deployment started',
            filename: filename
        });
        
    } catch (error) {
        console.error('Deployment error:', error);
        res.status(500).json({ error: error.message });
    }
});

// Parse Start-Pipeline.ps1 output and broadcast step status updates.
// Matches the actual output format produced by Write-StepHeader / Write-Result.
//
// IMPORTANT: pwsh.exe pipes stdout through Windows CP437 (OEM) encoding, so
// Unicode symbols like ► (U+25BA→0x10), ✓ (U+2713), ✗ (U+2717), ⏭ (U+23ED)
// arrive garbled. All matching is done on plain ASCII words only.
function parseDeploymentOutput(output) {
    // Dry runs do not update step tiles — only log output is shown
    if (activeDeployment && activeDeployment.isDryRun) return;

    // Strip ANSI/VT escape sequences (colour codes etc.)
    const cleaned = output.replace(/\x1B(?:\[[0-9;]*[mGKHFJA-Za-z])/g, '');
    const lines   = cleaned.split(/\r?\n/);

    lines.forEach(line => {
        const t = line.trim();
        if (!t) return;

        // ── "  STEP N/15  ►  Name"  →  mark step N as running ─────────────────
        // The ► char is garbled (CP437 0x10 → \u0010), so we only match STEP N/M
        const stepStart = t.match(/\bSTEP\s+(\d+)\/\d+\b/);
        if (stepStart && !t.includes('SKIPPED')) {
            const n   = parseInt(stepStart[1]);
            const sid = `step${n}`;
            if (activeDeployment) {
                activeDeployment.currentStepNum       = n;
                activeDeployment.stepStatuses[sid]    = 'running';
                activeDeployment.linesSinceStepHeader = 0;
            }
            broadcast({ type: 'step_update', step: sid, status: 'running' });
            return;
        }

        // Increment lines-since-header counter for all non-STEP lines
        if (activeDeployment) activeDeployment.linesSinceStepHeader++;

        // ── "[Step N/15] SKIPPED (StartAtStep=X)"  →  skipped ─────────────────
        const earlySkip = t.match(/\[Step\s+(\d+)\/\d+\]\s+SKIPPED/i);
        if (earlySkip) {
            const n   = parseInt(earlySkip[1]);
            const sid = `step${n}`;
            if (activeDeployment) activeDeployment.stepStatuses[sid] = 'skipped';
            broadcast({ type: 'step_update', step: sid, status: 'skipped' });
            return;
        }

        // ── "SUCCEEDED  (elapsed Xs)"  →  mark current step completed ─────────
        if (t.includes('SUCCEEDED') && t.includes('elapsed')) {
            if (activeDeployment && activeDeployment.currentStepNum) {
                const sid = `step${activeDeployment.currentStepNum}`;
                activeDeployment.stepStatuses[sid] = 'completed';
                broadcast({ type: 'step_update', step: sid, status: 'completed' });
            }
            return;
        }

        // ── "FAILED  (exit code N, elapsed Xs)" or unhandled exception ─────────
        if ((t.includes('FAILED') && (t.includes('elapsed') || t.includes('exit code'))) ||
             t.includes('Unhandled exception')) {
            if (activeDeployment && activeDeployment.currentStepNum) {
                const sid = `step${activeDeployment.currentStepNum}`;
                activeDeployment.stepStatuses[sid] = 'failed';
                broadcast({ type: 'step_update', step: sid, status: 'failed' });
            }
            return;
        }

        // ── "⏭ Skipped — reason"  (conditional / N/A step skip) ──────────────
        // This line is emitted by Start-Pipeline.ps1 immediately after the STEP
        // header (within ~3 lines). We guard with linesSinceStepHeader to avoid
        // false positives from inner scripts that print "Skipped" in their own output.
        if (/\bSkipped\b/.test(t) && activeDeployment && activeDeployment.linesSinceStepHeader <= 4) {
            if (activeDeployment.currentStepNum) {
                const sid = `step${activeDeployment.currentStepNum}`;
                activeDeployment.stepStatuses[sid] = 'skipped';
                broadcast({ type: 'step_update', step: sid, status: 'skipped' });
            }
            return;
        }
    });
}

// API: Run an arbitrary PowerShell command in the Nutanix-ZTI working directory
app.post('/api/terminal/run', requireAuth, (req, res) => {
    const { command } = req.body;
    if (!command || typeof command !== 'string') {
        return res.status(400).json({ error: 'command is required' });
    }
    // Limit command length as a basic safeguard
    if (command.length > 2000) {
        return res.status(400).json({ error: 'command too long' });
    }

    const initCmd = `$OutputEncoding = [System.Text.UTF8Encoding]::new($false); [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); $PSStyle.OutputRendering = 'Ansi'; `;
    const proc = spawn('pwsh.exe', [
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-Command', initCmd + command
    ], {
        cwd: path.dirname(deployScriptPath),
        env: Object.assign({}, process.env, {
            TERM: 'xterm-256color',
            DOTNET_SYSTEM_CONSOLE_ALLOW_ANSI_COLOR_REDIRECTION: '1'
        })
    });
    proc.stdout.setEncoding('utf8');
    proc.stderr.setEncoding('utf8');

    let stdout = '';
    let stderr = '';
    let done   = false;

    proc.stdout.on('data', d => { stdout += d.toString(); });
    proc.stderr.on('data', d => { stderr += d.toString(); });

    proc.on('close', code => {
        if (done) return;
        done = true;
        res.json({ exitCode: code, output: stdout, error: stderr });
    });

    proc.on('error', err => {
        if (done) return;
        done = true;
        res.status(500).json({ error: err.message });
    });

    // Safety timeout — kill after 120s
    setTimeout(() => {
        if (!done) {
            done = true;
            try { proc.kill(); } catch (_) {}
            res.json({ exitCode: -1, output: stdout, error: 'Timed out after 120s' });
        }
    }, 120000);
});

// API: Get deployment status
app.get('/api/deploy/status', requireAuth, (req, res) => {
    if (activeDeployment) {
        res.json({
            active: true,
            filename: activeDeployment.filename,
            startTime: activeDeployment.startTime
        });
    } else {
        res.json({ active: false });
    }
});

// API: Get dashboard data
app.get('/api/dashboard/statistics', requireAuth, (req, res) => {
    try {
        const data = loadDeployments();
        res.json(data.statistics);
    } catch (error) {
        console.error('Error loading dashboard statistics:', error);
        res.status(500).json({ error: 'Failed to load statistics' });
    }
});

app.get('/api/dashboard/deployments', requireAuth, (req, res) => {
    try {
        const data = loadDeployments();
        const limit = parseInt(req.query.limit) || 50;
        res.json({
            deployments: data.deployments.slice(0, limit)
        });
    } catch (error) {
        console.error('Error loading deployments:', error);
        res.status(500).json({ error: 'Failed to load deployments' });
    }
});

app.get('/api/dashboard/audit-logs', requireAuth, (req, res) => {
    try {
        const data = loadAuditLogs();
        const limit = parseInt(req.query.limit) || 100;
        res.json({
            logs: data.logs.slice(0, limit)
        });
    } catch (error) {
        console.error('Error loading audit logs:', error);
        res.status(500).json({ error: 'Failed to load audit logs' });
    }
});

// API: Serve README files as plain text for the Help page
app.get('/api/readme/app', requireAuth, (req, res) => {
    const readmePath = path.join(__dirname, 'README.md');
    try {
        const content = fs.readFileSync(readmePath, 'utf8');
        res.type('text/plain; charset=utf-8').send(content);
    } catch (_) {
        res.status(404).json({ error: 'README not found' });
    }
});

app.get('/api/readme/workflow', requireAuth, (req, res) => {
    const readmePath = path.join(__dirname, '..', 'Nutanix-ZTI', 'README.md');
    try {
        const content = fs.readFileSync(readmePath, 'utf8');
        res.type('text/plain; charset=utf-8').send(content);
    } catch (_) {
        res.status(404).json({ error: 'README not found' });
    }
});

// Global error handler
app.use((err, req, res, next) => {
    console.error('Unhandled error:', err);
    res.status(500).json({ 
        error: 'Internal server error',
        message: err.message,
        stack: process.env.NODE_ENV === 'development' ? err.stack : undefined
    });
});

// Handle 404
app.use((req, res) => {
    res.status(404).json({ error: 'Not found' });
});

// Function to clean up old data (older than 30 days)
function cleanupOldData() {
    try {
        const thirtyDaysAgo = new Date();
        thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
        
        console.log('Running cleanup for data older than 30 days...');
        
        // Clean deployments
        const deploymentData = loadDeployments();
        const originalDeploymentCount = deploymentData.deployments.length;
        
        deploymentData.deployments = deploymentData.deployments.filter(deployment => {
            const deploymentDate = new Date(deployment.timestamp);
            return deploymentDate >= thirtyDaysAgo;
        });
        
        // Recalculate statistics
        deploymentData.statistics = {
            total: deploymentData.deployments.length,
            dryRun: deploymentData.deployments.filter(d => d.isDryRun).length,
            production: deploymentData.deployments.filter(d => !d.isDryRun).length,
            successful: deploymentData.deployments.filter(d => d.success).length,
            failed: deploymentData.deployments.filter(d => !d.success).length
        };
        
        if (originalDeploymentCount !== deploymentData.deployments.length) {
            fs.writeFileSync(deploymentsFilePath, JSON.stringify(deploymentData, null, 2));
            console.log(`Cleaned ${originalDeploymentCount - deploymentData.deployments.length} old deployment records. Kept: ${deploymentData.deployments.length}`);
        }
        
        // Clean audit logs
        const auditData = loadAuditLogs();
        const originalLogCount = auditData.logs.length;
        
        auditData.logs = auditData.logs.filter(log => {
            const logDate = new Date(log.timestamp);
            return logDate >= thirtyDaysAgo;
        });
        
        if (originalLogCount !== auditData.logs.length) {
            fs.writeFileSync(auditLogsFilePath, JSON.stringify(auditData, null, 2));
            console.log(`Cleaned ${originalLogCount - auditData.logs.length} old audit log entries. Kept: ${auditData.logs.length}`);
        }
        
        if (originalDeploymentCount === deploymentData.deployments.length && originalLogCount === auditData.logs.length) {
            console.log('No old data to clean up.');
        }
    } catch (error) {
        console.error('Error during cleanup:', error);
    }
}

// Start server
server.listen(PORT, () => {
    console.log(`Nutanix ZTI Configuration Server running at https://localhost:${PORT}`);
    console.log(`Configuration files: ${configsPath}`);
    console.log(`Deployment script: ${deployScriptPath}`);
    console.log('WebSocket server ready for real-time updates');
    console.log('Data retention: 30 days');
    console.log('Press Ctrl+C to stop the server');
    
    // Run initial cleanup on startup
    cleanupOldData();
    
    // Schedule daily cleanup at midnight
    const now = new Date();
    const midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, 0, 0, 0);
    const timeUntilMidnight = midnight - now;
    
    setTimeout(() => {
        cleanupOldData();
        // Run cleanup daily
        setInterval(cleanupOldData, 24 * 60 * 60 * 1000);
    }, timeUntilMidnight);
    
    console.log('Daily cleanup scheduled for midnight');
});
