var Service = require('node-windows').Service;

var svc = new Service({
  name: 'Nutanix Cluster Deployment Web',
  description: 'Web interface for Nutanix cluster deployment with HTTPS support',
  script: 'E:\\SOAAA\\ZTIPS\\deploy-cluster-app\\server.js',
  nodeOptions: [
    '--harmony',
    '--max_old_space_size=4096'
  ]
});

svc.on('install', function(){
  console.log('Service installed successfully!');
  console.log('The service will start automatically.');
  svc.start();
});

svc.on('alreadyinstalled', function(){
  console.log('This service is already installed.');
});

svc.on('start', function(){
  console.log(svc.name + ' started!');
  console.log('Access the web interface at: https://localhost:3443');
});

svc.install();