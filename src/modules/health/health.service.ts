/**
 * HealthService — liveness/readiness probe.
 *
 * Verifies the server process and the PostgreSQL connection.
 * The database is checked with a trivial `SELECT 1` through Prisma so the
 * status always reflects reality (Connected/Disconnected).
 */

import { Injectable } from '@nestjs/common';
import { PrismaService } from '../../database/prisma.service';
import type { HealthStatus } from '../../types/api-response';

export const API_VERSION = '1.0.0';

@Injectable()
export class HealthService {
  constructor(private readonly prisma: PrismaService) {}

  async check(): Promise<HealthStatus> {
    let database: HealthStatus['database'] = 'Connected';

    try {
      await this.prisma.$queryRaw`SELECT 1`;
    } catch {
      database = 'Disconnected';
    }

    return {
      success: true,
      status: database === 'Connected' ? 'OK' : 'DEGRADED',
      database,
      server: 'Running',
      version: API_VERSION,
    };
  }
}
