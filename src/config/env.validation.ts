/**
 * Environment variable validation.
 *
 * The `validate` function is passed to ConfigModule.forRoot({ validate }).
 * It runs before the application boots and rejects missing/malformed
 * required variables with a clear, aggregated error message.
 */

import { plainToInstance, Type } from 'class-transformer';
import {
  IsEnum,
  IsInt,
  IsNotEmpty,
  IsOptional,
  IsString,
  Min,
  validateSync,
} from 'class-validator';

export enum NodeEnv {
  Development = 'development',
  Production = 'production',
  Test = 'test',
}

export class EnvironmentVariables {
  @IsEnum(NodeEnv)
  @IsNotEmpty()
  NODE_ENV: NodeEnv;

  @Type(() => Number)
  @IsInt()
  @Min(1)
  @IsNotEmpty()
  PORT: number;

  @IsString()
  @IsNotEmpty()
  DATABASE_URL: string;

  @IsString()
  @IsNotEmpty()
  JWT_SECRET: string;

  @IsString()
  @IsNotEmpty()
  JWT_REFRESH_SECRET: string;

  @IsOptional()
  @IsString()
  CORS_ORIGINS?: string;

  @Type(() => Number)
  @IsOptional()
  @IsInt()
  @Min(1)
  RATE_LIMIT_TTL_MS?: number;

  @Type(() => Number)
  @IsOptional()
  @IsInt()
  @Min(1)
  RATE_LIMIT_MAX?: number;

  @IsOptional()
  @IsString()
  LOG_LEVEL?: string;

  @IsOptional()
  @IsString()
  FILE_STORAGE_BUCKET?: string;

  @IsOptional()
  @IsString()
  FILE_STORAGE_REGION?: string;

  @IsOptional()
  @IsString()
  FILE_STORAGE_ACCESS_KEY_ID?: string;

  @IsOptional()
  @IsString()
  FILE_STORAGE_SECRET_ACCESS_KEY?: string;

  @IsOptional()
  @IsString()
  PUSH_NOTIFICATIONS_URL?: string;

  @IsOptional()
  @IsString()
  PUSH_NOTIFICATIONS_APP_ID?: string;

  @IsOptional()
  @IsString()
  MAPS_API_KEY?: string;

  @IsOptional()
  @IsString()
  EMAIL_SERVICE_URL?: string;

  @IsOptional()
  @IsString()
  EMAIL_SERVICE_API_KEY?: string;
}

/**
 * Validates the raw process.env object at boot time.
 * Throws an aggregated error listing every invalid variable.
 */
export function validateEnv(
  config: Record<string, unknown>,
): EnvironmentVariables {
  const validated = plainToInstance(EnvironmentVariables, config, {
    enableImplicitConversion: true,
    exposeDefaultValues: true,
  });

  const errors = validateSync(validated, {
    skipMissingProperties: false,
    whitelist: true,
  });

  if (errors.length > 0) {
    const details = errors
      .map((error) => {
        const constraints = Object.values(error.constraints ?? {});
        return `  - ${error.property}: ${constraints.join(', ')}`;
      })
      .join('\n');

    throw new Error(
      `[env] Invalid environment configuration — fix these variables before starting:\n${details}`,
    );
  }

  return validated;
}
