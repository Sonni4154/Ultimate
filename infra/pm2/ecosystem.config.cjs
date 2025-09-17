module.exports = {
  apps: [
    { name: "api", script: "apps/server/dist/index.js", env: { NODE_ENV: "production", PORT: 3000 } }
  ]
};
