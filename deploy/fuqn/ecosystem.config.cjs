// Process list for the single-container fuqn.ai base image.
// The three Postiz production processes match the upstream pm2 scripts.

module.exports = {
  apps: [
    {
      name: 'backend',
      cwd: '/app/apps/backend',
      script: 'pnpm',
      args: 'start',
      interpreter: 'none',
      exec_mode: 'fork',
      autorestart: true,
      max_restarts: 30,
      restart_delay: 5000,
      kill_timeout: 10000,
    },
    {
      name: 'frontend',
      cwd: '/app/apps/frontend',
      script: 'pnpm',
      args: 'start',
      interpreter: 'none',
      exec_mode: 'fork',
      autorestart: true,
      max_restarts: 30,
      restart_delay: 5000,
      kill_timeout: 10000,
    },
    {
      name: 'orchestrator',
      cwd: '/app/apps/orchestrator',
      script: 'pnpm',
      args: 'start',
      interpreter: 'none',
      exec_mode: 'fork',
      autorestart: true,
      max_restarts: 30,
      restart_delay: 5000,
      kill_timeout: 10000,
    },
  ],
};
