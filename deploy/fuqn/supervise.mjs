import { spawn } from 'node:child_process';

const children = new Set();
const timers = new Set();
let stopping = false;

function start(name, command, args, cwd) {
  const child = spawn(command, args, {
    cwd,
    env: process.env,
    stdio: 'inherit',
  });
  children.add(child);
  child.on('exit', (code, signal) => {
    children.delete(child);
    if (stopping) {
      return;
    }
    console.error(
      `fuqn: ${name} exited (${signal || code}); restarting in 3s`
    );
    const timer = setTimeout(() => {
      timers.delete(timer);
      start(name, command, args, cwd);
    }, 3000);
    timers.add(timer);
  });
}

function stop() {
  if (stopping) {
    return;
  }
  stopping = true;
  for (const timer of timers) {
    clearTimeout(timer);
  }
  for (const child of children) {
    child.kill('SIGTERM');
  }
  setTimeout(() => {
    for (const child of children) {
      child.kill('SIGKILL');
    }
    process.exit(0);
  }, 15000).unref();
}

process.on('SIGTERM', stop);
process.on('SIGINT', stop);

start('nginx', 'nginx', ['-c', '/etc/nginx/nginx.conf', '-g', 'daemon off;'], '/');
start(
  'backend',
  'node',
  ['--experimental-require-module', 'dist/apps/backend/src/main.js'],
  '/app/apps/backend'
);
start(
  'frontend',
  'node',
  ['/app/node_modules/next/dist/bin/next', 'start', '-p', '4200'],
  '/app/apps/frontend'
);
start(
  'orchestrator',
  'node',
  ['--experimental-require-module', 'dist/apps/orchestrator/src/main.js'],
  '/app/apps/orchestrator'
);
