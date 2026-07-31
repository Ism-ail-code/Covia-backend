import {
  INestApplication,
  ValidationPipe,
  VersioningType,
} from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import request from 'supertest';
import { App } from 'supertest/types';
import { AppModule } from './../src/app.module';
import type {
  ApiSuccessResponse,
  HealthResponse,
} from './../src/types/api-response';

function asHealth(body: unknown): ApiSuccessResponse<HealthResponse> {
  return body as ApiSuccessResponse<HealthResponse>;
}

function asError(body: unknown): {
  success: boolean;
  message: string;
  statusCode: number;
  path: string;
} {
  return body as {
    success: boolean;
    message: string;
    statusCode: number;
    path: string;
  };
}

describe('Covia API (e2e)', () => {
  let app: INestApplication<App>;

  beforeAll(async () => {
    const moduleFixture: TestingModule = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();

    app = moduleFixture.createNestApplication();
    app.setGlobalPrefix('api');
    app.enableVersioning({
      type: VersioningType.URI,
      defaultVersion: '1',
    });
    app.useGlobalPipes(
      new ValidationPipe({
        whitelist: true,
        transform: true,
      }),
    );
    await app.init();
  });

  afterAll(async () => {
    await app.close();
  });

  it('GET /api/v1/health - returns service status envelope', async () => {
    const response = await request(app.getHttpServer())
      .get('/api/v1/health')
      .expect(200);

    const body = asHealth(response.body);
    expect(body).toMatchObject({
      success: true,
      status: 'OK',
      database: 'Connected',
      server: 'Running',
      version: '1.0.0',
    });
    expect(body.path).toBe('/api/v1/health');
    expect(body.requestId).toEqual(expect.any(String));
  });

  it('GET /api/v1/health - reflects request-id header', async () => {
    const response = await request(app.getHttpServer())
      .get('/api/v1/health')
      .set('x-request-id', 'e2e-trace-123')
      .expect(200);

    const body = asHealth(response.body);
    expect(body.requestId).toBe('e2e-trace-123');
  });

  it('GET /api/v1/health - uses v1 only, not v2', async () => {
    await request(app.getHttpServer()).get('/api/v2/health').expect(404);
  });

  it('GET /unknown - returns standardized error envelope', async () => {
    const response = await request(app.getHttpServer())
      .get('/api/v1/unknown')
      .expect(404);

    const body = asError(response.body);
    expect(body).toMatchObject({
      success: false,
      statusCode: 404,
      path: '/api/v1/unknown',
    });
    expect(typeof body.message).toBe('string');
  });
});
