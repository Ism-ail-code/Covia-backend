/**
 * Centralised, typed access to environment variables.
 *
 * Every value is read from process.env once and exposed through a typed
 * configuration object so that the rest of the application never touches
 * process.env directly. Secrets are never logged or hardcoded.
 */

export interface AppConfig {
  env: 'development' | 'production' | 'test';
  port: number;
  api: {
    globalPrefix: string;
    version: string;
  };
  database: {
    url: string;
  };
  jwt: {
    secret: string;
    refreshSecret: string;
  };
  cors: {
    origins: boolean | string[];
  };
  rateLimit: {
    ttlMs: number;
    max: number;
  };
  log: {
    level: string;
  };
  integrations: {
    fileStorage: { bucket: string; region: string };
    pushNotifications: { url: string; appId: string };
    mapsApi: { key: string };
    emailService: { url: string; apiKey: string };
  };
}

export default (): AppConfig => {
  const env = (process.env.NODE_ENV ?? 'development') as AppConfig['env'];

  const commaList = (value?: string) =>
    value
      ? value
          .split(',')
          .map((v) => v.trim())
          .filter(Boolean)
      : undefined;

  return {
    env,
    port: Number(process.env.PORT ?? 3000),
    api: {
      globalPrefix: 'api',
      version: 'v1',
    },
    database: {
      url: process.env.DATABASE_URL ?? '',
    },
    jwt: {
      secret: process.env.JWT_SECRET ?? '',
      refreshSecret: process.env.JWT_REFRESH_SECRET ?? '',
    },
    cors: {
      origins: commaList(process.env.CORS_ORIGINS) ?? true,
    },
    rateLimit: {
      ttlMs: Number(process.env.RATE_LIMIT_TTL_MS ?? 60_000),
      max: Number(process.env.RATE_LIMIT_MAX ?? 100),
    },
    log: {
      level: process.env.LOG_LEVEL ?? 'info',
    },
    integrations: {
      fileStorage: {
        bucket: process.env.FILE_STORAGE_BUCKET ?? '',
        region: process.env.FILE_STORAGE_REGION ?? '',
      },
      pushNotifications: {
        url: process.env.PUSH_NOTIFICATIONS_URL ?? '',
        appId: process.env.PUSH_NOTIFICATIONS_APP_ID ?? '',
      },
      mapsApi: {
        key: process.env.MAPS_API_KEY ?? '',
      },
      emailService: {
        url: process.env.EMAIL_SERVICE_URL ?? '',
        apiKey: process.env.EMAIL_SERVICE_API_KEY ?? '',
      },
    },
  };
};
