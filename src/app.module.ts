/**
 * AppModule — application root.
 *
 * Composes the global infrastructure:
 *   - ConfigModule        → validated environment configuration
 *   - LoggerModule        → structured request/application logging (pino)
 *   - DatabaseModule      → global PrismaService (PostgreSQL)
 *   - ThrottlerModule     → rate limiting infrastructure
 *   - HealthModule        → GET /api/v1/health
 *
 * Global providers:
 *   - AllExceptionsFilter  → standardized error responses
 *   - ThrottlerGuard       → rate limiting enforcement
 *   - TransformInterceptor → standardized success envelope
 *
 * RequestIdMiddleware is applied to every route so logs and responses
 * carry a traceable request id.
 */

import { MiddlewareConsumer, Module, NestModule } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { APP_FILTER, APP_GUARD, APP_INTERCEPTOR } from '@nestjs/core';
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';
import { LoggerModule } from 'nestjs-pino';
import { randomUUID } from 'crypto';
import type { IncomingMessage, ServerResponse } from 'http';
import { validateEnv } from './config/env.validation';
import { DatabaseModule } from './database/database.module';
import { AllExceptionsFilter } from './filters/all-exceptions.filter';
import { TransformInterceptor } from './interceptors/transform.interceptor';
import {
  REQUEST_ID_HEADER,
  RequestIdMiddleware,
} from './middleware/request-id.middleware';
import { HealthModule } from './modules/health/health.module';

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      cache: true,
      validate: validateEnv,
      envFilePath: ['.env.local', '.env'],
    }),
    LoggerModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService) => {
        const isProduction = config.get<string>('NODE_ENV') === 'production';
        return {
          pinoHttp: {
            level: config.get<string>('LOG_LEVEL') ?? 'info',
            // Reuse the request id stamped by RequestIdMiddleware.
            genReqId: (req: IncomingMessage, res: ServerResponse) => {
              const incoming = req.headers[REQUEST_ID_HEADER];
              const id =
                (Array.isArray(incoming) ? incoming[0] : incoming) ??
                randomUUID();
              res.setHeader(REQUEST_ID_HEADER, id);
              return id;
            },
            // Never log sensitive headers.
            redact: {
              paths: [
                'req.headers.authorization',
                'req.headers.cookie',
                'req.headers["x-api-key"]',
              ],
              censor: '[REDACTED]',
            },
            transport: isProduction
              ? undefined // structured JSON on stdout in production
              : {
                  target: 'pino-pretty',
                  options: {
                    singleLine: true,
                    colorize: true,
                    translateTime: 'HH:MM:ss',
                  },
                },
          },
        };
      },
    }),
    ThrottlerModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService) => [
        {
          ttl: config.get<number>('RATE_LIMIT_TTL_MS') ?? 60_000,
          limit: config.get<number>('RATE_LIMIT_MAX') ?? 100,
        },
      ],
    }),
    DatabaseModule,
    HealthModule,
  ],
  providers: [
    { provide: APP_FILTER, useClass: AllExceptionsFilter },
    { provide: APP_GUARD, useClass: ThrottlerGuard },
    { provide: APP_INTERCEPTOR, useClass: TransformInterceptor },
  ],
})
export class AppModule implements NestModule {
  configure(consumer: MiddlewareConsumer): void {
    consumer.apply(RequestIdMiddleware).forRoutes('*');
  }
}
