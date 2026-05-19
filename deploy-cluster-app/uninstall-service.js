var Service = require('node-windows').Service;

var svc = new Service({
  name: 'Nutanix Cluster Deployment Web',
  script: 'E:\\SOAAA\\ZTIPS\\deploy-cluster-app\\server.js'
});

svc.on('uninstall', function(){
  console.log('Service uninstalled successfully!');
  console.log('The service has been removed.');
});

svc.on('error', function(err){
  console.error('Error during uninstall:', err);
});

console.log('Uninstalling Nutanix Cluster Deployment Web service...');
svc.uninstall();
