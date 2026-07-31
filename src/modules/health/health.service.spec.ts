import { Test, TestingModule } from '@nestjs/testing';
import { PrismaService } from '../../database/prisma.service';
import { HealthService } from './health.service';

describe('HealthService', () => {
  let service: HealthService;
  const prisma = { $queryRaw: jest.fn() };

  beforeEach(async () => {
    jest.resetAllMocks();
    const module: TestingModule = await Test.createTestingModule({
      providers: [HealthService, { provide: PrismaService, useValue: prisma }],
    }).compile();

    service = module.get<HealthService>(HealthService);
  });

  it('returns OK when the database answers', async () => {
    prisma.$queryRaw.mockResolvedValueOnce([]);
    const result = await service.check();

    expect(result).toEqual({
      success: true,
      status: 'OK',
      database: 'Connected',
      server: 'Running',
      version: '1.0.0',
    });
  });

  it('returns DEGRADED when the database is unreachable', async () => {
    prisma.$queryRaw.mockRejectedValueOnce(new Error('connection refused'));
    const result = await service.check();

    expect(result).toEqual({
      success: true,
      status: 'DEGRADED',
      database: 'Disconnected',
      server: 'Running',
      version: '1.0.0',
    });
  });
});
