/**
 * HealthController — GET /api/v1/health
 *
 * Boot check for the backend: verifies the server and database.
 */

import { Controller, Get } from '@nestjs/common';
import { ApiOkResponse, ApiOperation, ApiTags } from '@nestjs/swagger';
import { HealthService } from './health.service';
import type { HealthStatus } from '../../types/api-response';

@ApiTags('health')
@Controller({ path: 'health', version: '1' })
export class HealthController {
  constructor(private readonly healthService: HealthService) {}

  @Get()
  @ApiOperation({
    summary: 'Health check',
    description: 'Reports server and database status.',
  })
  @ApiOkResponse({
    description:
      'Backend is running and its database connectivity is reported.',
    schema: {
      example: {
        success: true,
        status: 'OK',
        database: 'Connected',
        server: 'Running',
        version: '1.0.0',
      },
    },
  })
  check(): Promise<HealthStatus> {
    return this.healthService.check();
  }
}
