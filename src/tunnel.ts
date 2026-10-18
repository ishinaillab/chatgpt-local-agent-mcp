export type TunnelLaunch = {
  args: string[];
  extraEnv: Record<string, string>;
  mode: "remote" | "local";
};

/**
 * Remote-managed tunnels require TUNNEL_TOKEN in the child environment.
 * Never pass the token on the command line, where process listings expose it.
 * Without a token, retain the locally-managed config.yml launch behavior.
 */
export function tunnelLaunch(configPath: string, tunnelName: string, token: string | undefined): TunnelLaunch {
  const privateToken = token?.trim();
  if (privateToken) {
    return {
      args: ["tunnel", "run"],
      extraEnv: { TUNNEL_TOKEN: privateToken },
      mode: "remote",
    };
  }
  return {
    args: ["tunnel", "--config", configPath, "run", tunnelName],
    extraEnv: {},
    mode: "local",
  };
}
