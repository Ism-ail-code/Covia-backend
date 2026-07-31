/**
 * Covia backend — bootstrap.
 *
 * Wires up the full Phase 1 infrastructure:
 *   - structured logging (pino via nestjs-pino)
 *   - global prefix `api` + URI versioning → routes at /api/v1/*
 *   - CORS, Helmet security headers, gzip compression
 *   - global validation pipe (whitelist + transform)
 *   - Swagger/OpenAPI docs at /api/docs (development only)
 */

import { ValidationPipe, VersioningType } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import compression from 'compression';
import helmet from 'helmet';
import { Logger } from 'nestjs-pino';
import { AppModule } from './app.module';
import { API_VERSION } from './modules/health/health.service';

async function bootstrap(): Promise<void> {
  const app = await NestFactory.create(AppModule, { bufferLogs: true });
  const logger = app.get(Logger);
  app.useLogger(logger);

  const config = app.get(ConfigService);

  // ── API prefix + versioning → /api/v1/* ──────────────────────────
  app.setGlobalPrefix('api');
  app.enableVersioning({
    type: VersioningType.URI,
    defaultVersion: '1',
  });

  // ── Security foundations ─────────────────────────────────────────
  app.use(helmet());
  app.enableCors({
    origin:
      config
        .get<string>('CORS_ORIGINS')
        ?.split(',')
        .map((o) => o.trim()) ?? true,
    credentials: true,
  });

  // ── Compression ──────────────────────────────────────────────────
  app.use(compression());

  // ── Global validation ────────────────────────────────────────────
  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true, // strip properties without decorators
      transform: true, // convert payloads to DTO instances
      transformOptions: { enableImplicitConversion: false },
      stopAtFirstError: false,
    }),
  );

  // ── Swagger / OpenAPI (development only) ─────────────────────────
  if (config.get<string>('NODE_ENV') !== 'production') {
    const swaggerConfig = new DocumentBuilder()
      .setTitle('Covia API')
      .setDescription(
        'Backend foundation for Covia — coordinating shared rides booked through third-party ride-hailing services.',
      )
      .setVersion(API_VERSION)
      .addBearerAuth(
        { type: 'http', scheme: 'bearer', bearerFormat: 'JWT' },
        'access-token',
      )
      .build();
    const document = SwaggerModule.createDocument(app, swaggerConfig);
    SwaggerModule.setup('api/docs', app, document);
    logger.log('Swagger documentation available at /api/docs', 'Bootstrap');
  }

  app.enableShutdownHooks();

  const port = config.get<number>('PORT') ?? 3000;
  await app.listen(port);
  logger.log(
    `Covia API running on http://localhost:${port}/api/v1`,
    'Bootstrap',
  );
}

void bootstrap();
