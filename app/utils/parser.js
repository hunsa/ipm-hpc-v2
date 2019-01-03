/* eslint-disable */

const fs = require('fs');
const parseString = require('xml2js').parseString;

const ROOT_ITEM = 'ipm_job_profile';

export const parseData = (filename, callback) => {
  parseXml(filename, result => {
    console.log(`${filename}:`);
    let taskdata = result[ROOT_ITEM].task[0];
    var metadata = {};
    metadata.id = taskdata.job[0]._;
    metadata.cmd = taskdata.cmdline[0]._;
    metadata.codename = '';
    metadata.username = taskdata.$.username;
    metadata.host =
      taskdata.host[0]._ + ' (' + taskdata.host[0].$.mach_info + ')';
    metadata.start = taskdata.$.stamp_init;
    metadata.stop = taskdata.$.stamp_final;
    metadata.totalMemory = '';
    metadata.switchSend = '';
    metadata.state = '';
    metadata.group = taskdata.$.groupname;
    metadata.mpiTasks = '';
    metadata.wallClock = '';
    metadata.comm = '';
    metadata.totalGflopSec = '';
    metadata.switchRecv = '';
    callback(JSON.stringify(metadata, null, 2));
  });
};

function parseXml(file, callback) {
  fs.readFile(file, (err, data) => {
    parseString(data, (err, result) => callback(result));
  });
}
